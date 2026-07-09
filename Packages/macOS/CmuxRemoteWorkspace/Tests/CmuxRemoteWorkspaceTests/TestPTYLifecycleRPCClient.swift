import CmuxRemoteDaemon
import Foundation
@testable import CmuxRemoteWorkspace

/// Thread-safe PTY lifecycle RPC fake for tunnel ownership tests.
final class TestPTYLifecycleRPCClient: RemotePTYLifecycleRPCClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _closedSessionIDs: [String] = []
    private var _closeError: (any Error)?

    var closedSessionIDs: [String] { lock.withLock { _closedSessionIDs } }

    func failClose(with error: any Error) { lock.withLock { _closeError = error } }

    func listPTY() throws -> [[String: Any]] { [] }

    func closePTY(sessionID: String) throws {
        let error = lock.withLock {
            _closedSessionIDs.append(sessionID)
            return _closeError
        }
        if let error { throw error }
    }

    func resizePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        cols: Int,
        rows: Int
    ) throws {}

    func detachPTYChecked(sessionID: String, attachmentID: String, attachmentToken: String) throws {}

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
        RemotePTYBridgeAttachment(attachmentID: attachmentID, token: "token")
    }

    func writePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        data: Data,
        seq: UInt64?,
        completion: @escaping ((any Error)?) -> Void
    ) { completion(nil) }

    func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {}
}
