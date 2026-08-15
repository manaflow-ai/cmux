import CmuxRemoteDaemon
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
