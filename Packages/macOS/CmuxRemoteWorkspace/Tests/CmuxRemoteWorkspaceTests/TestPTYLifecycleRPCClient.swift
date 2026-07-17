import CmuxRemoteDaemon
import Foundation
@testable import CmuxRemoteWorkspace

/// Thread-safe PTY lifecycle RPC fake for tunnel ownership tests.
final class TestPTYLifecycleRPCClient: RemoteDaemonTunnelRPCClient, @unchecked Sendable {
    private let lock = NSLock()
    private let delaysAttach: Bool
    private let attachStarted = DispatchSemaphore(value: 0)
    private let attachRelease = DispatchSemaphore(value: 0)
    private let attachReturned = DispatchSemaphore(value: 0)
    private let closeStarted = DispatchSemaphore(value: 0)
    private let fileStatStarted = DispatchSemaphore(value: 0)
    private let fileStatRelease = DispatchSemaphore(value: 0)
    private var _closedSessionIDs: [String] = []
    private var _closeError: (any Error)?
    private var _fileStatTimeout: TimeInterval?

    init(delaysAttach: Bool = false) {
        self.delaysAttach = delaysAttach
    }

    var closedSessionIDs: [String] { lock.withLock { _closedSessionIDs } }
    var fileStatTimeout: TimeInterval? { lock.withLock { _fileStatTimeout } }

    func failClose(with error: any Error) { lock.withLock { _closeError = error } }

    func waitForAttachStart() -> DispatchTimeoutResult {
        attachStarted.wait(timeout: .now() + 2)
    }

    func releaseAttach() {
        attachRelease.signal()
    }

    func waitForAttachReturn() -> DispatchTimeoutResult {
        attachReturned.wait(timeout: .now() + 2)
    }

    func waitForCloseStart(timeout: DispatchTime) -> DispatchTimeoutResult {
        closeStarted.wait(timeout: timeout)
    }

    func waitForFileStatStart(timeout: DispatchTime) -> DispatchTimeoutResult {
        fileStatStarted.wait(timeout: timeout)
    }

    func releaseFileStat() {
        fileStatRelease.signal()
    }

    func listPTY() throws -> [[String: Any]] { [] }

    func stop() {}

    func openStream(host: String, port: Int, timeoutMs: Int) throws -> String {
        throw NSError(domain: "test.remote.proxy", code: 1)
    }

    func writeStream(streamID: String, data: Data) throws {}

    func attachStream(
        streamID: String,
        queue: DispatchQueue,
        onEvent: @escaping (RemoteDaemonStreamEvent) -> Void
    ) throws {}

    func closeStream(streamID: String) {}

    func statFile(path: String, timeout: TimeInterval) throws -> RemoteDaemonFileStat {
        lock.withLock { _fileStatTimeout = timeout }
        fileStatStarted.signal()
        fileStatRelease.wait()
        return .missing
    }

    func closePTY(sessionID: String, timeout: TimeInterval) throws {
        closeStarted.signal()
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
        if delaysAttach {
            attachStarted.signal()
            attachRelease.wait()
            attachReturned.signal()
        }
        return RemotePTYBridgeAttachment(attachmentID: attachmentID, token: "token")
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
