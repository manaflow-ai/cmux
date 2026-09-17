struct RemoteHookInvocationBridgeError: Error {
    let code: String
    let message: String
}
