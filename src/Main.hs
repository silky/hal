module Main where

import Control.Monad (forever)
import Data.Aeson
import Data.ByteString hiding (head, unpack)
import Data.ByteString.Char8 hiding (head)
import GHC.Generics
import Network.HTTP.Simple
import System.Environment

data HardCodedEvent = HardCodedEvent
  { value  :: Int
  } deriving (Show, Generic)

-- | Lambda runtime error that we pass back to AWS
data LambdaError = LambdaError
  { errorMessage :: String,
    errorType    :: String,
    stackTrace   :: [String]
  } deriving (Show, Generic)

instance ToJSON HardCodedEvent
instance FromJSON HardCodedEvent
instance ToJSON LambdaError

-- | For pure functions that can still fail.
pureLambdaRuntime :: (FromJSON event, ToJSON result) =>
  (event -> Either String result) -> IO ()
pureLambdaRuntime fn = forever $ do
  -- Retreive settings
  awsLambdaRuntimeApi <- getEnv "AWS_LAMBDA_RUNTIME_API"
  baseRequest <- parseRequest $ "http://" ++ awsLambdaRuntimeApi

  -- Get an event
  nextRes <- httpJSON $ setRequestPath "2018-06-01/runtime/invocation/next" baseRequest

  -- Propagate the tracing header
  let traceId = head $ getResponseHeader "Lambda-Runtime-Trace-Id" nextRes
  setEnv "_X_AMZN_TRACE_ID" (unpack traceId)

  -- TODO: Create a context object
  let reqId = head $ getResponseHeader "Lambda-Runtime-Aws-Request-Id" nextRes

  let event = getResponseBody nextRes
  let result = fn event

  case result of
    Right r -> do
      -- Handle the response (successes)
      let successUrl
            = setRequestBodyJSON r
            $ setRequestMethod "POST"
            $ setRequestPath (Data.ByteString.concat ["2018-06-01/runtime/invocation/", reqId, "/response"])
            $ baseRequest
      _ <- httpNoBody successUrl

      -- TODO: Handle errors
      return ()

    Left e -> do
      let failureUrl
            = setRequestBodyJSON (LambdaError { errorMessage = e, stackTrace = [], errorType = "User"})
            $ setRequestHeader "Content-Type" ["application/vnd.aws.lambda.error+json"]
            $ setRequestMethod "POST"
            $ setRequestPath (Data.ByteString.concat ["2018-06-01/runtime/invocation/", reqId, "/error"])
            $ baseRequest
      _ <- httpNoBody failureUrl
      return ()

-- | For pure functions that can never fail.
simpleLambdaRuntime :: (FromJSON event, ToJSON result) => (event -> result) -> IO ()
simpleLambdaRuntime fn =  pureLambdaRuntime (Right . fn)

-- Some test functions
handler :: HardCodedEvent -> HardCodedEvent
handler = id

fallibleHandler :: HardCodedEvent -> Either String Int
fallibleHandler _ = Left "I always fail, sucker."

main :: IO ()
main = pureLambdaRuntime fallibleHandler