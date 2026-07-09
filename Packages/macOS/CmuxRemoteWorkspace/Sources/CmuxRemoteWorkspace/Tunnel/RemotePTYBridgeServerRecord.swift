/// One live local bridge server and the remote attachment identity it serves.
struct RemotePTYBridgeServerRecord {
    let server: RemotePTYBridgeServer
    let sessionID: String
    let attachmentID: String
}
