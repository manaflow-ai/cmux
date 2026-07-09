import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation

/// Unused RPC seam required to mint a real loopback bridge endpoint for coordinator tests.
final class IntentionalCleanupBridgeRPCClient: RemotePTYBridgeRPCClient, @unchecked Sendable {
    func attachBridgePTY(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int,
        command: String?,
        requireExisting: Bool,
        inputSeqAck: Bool,
        queue: DispatchQueue,
        onEvent: @escaping (RemotePTYBridgeEvent) -> Void
    ) throws -> RemotePTYBridgeAttachment {
        fatalError("Intentional cleanup tests never connect to the bridge endpoint")
    }

    func writePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        data: Data,
        seq: UInt64?,
        completion: @escaping ((any Error)?) -> Void
    ) {
        fatalError("Intentional cleanup tests never write through the bridge endpoint")
    }

    func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {}
}

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
