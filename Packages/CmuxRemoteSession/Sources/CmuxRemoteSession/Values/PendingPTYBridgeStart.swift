internal import CmuxRemoteWorkspace

/// A PTY-bridge start request parked until the daemon, proxy lease, and
/// proxy endpoint are all ready (`startPTYBridge(waitForReady: true)`).
/// Lifted one-for-one from the legacy controller's nested type.
struct PendingPTYBridgeStart {
    let sessionID: String
    let attachmentID: String
    let command: String?
    let requireExisting: Bool
    let isCancelled: () -> Bool
    let completion: (Result<RemotePTYBridgeServer.Endpoint, Error>) -> Void
}
