import CmuxRemoteWorkspace

/// Fixed strings required by the bridge server; no error is rendered in this test.
struct IntentionalCleanupBridgeStrings: RemotePTYBridgeStrings {
    let missingPersistentPTYCapability = "missing capability"
    let sessionEnded = "session ended"
    let inputBackedUp = "input backed up"
    let daemonTimeout = "daemon timeout"
    let attachFailed = "attach failed"

    func allocationDiagnostic(_ message: String) -> String {
        message
    }
}
