import CmuxNextWakeups
import Foundation
import Network
import Synchronization

/// A line-delimited JSON connection to a Unix socket (the CUA host's
/// framing). All state lives on one private serial queue; callbacks run there
/// and callers hop to their own actor.
nonisolated final class AgentActivityLineConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cmux.agent-activity.socket")
    private let connection: NWConnection
    private var buffer = Data()
    private var onLine: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var closed = false
    /// Called once by `expire()` (a one-shot request's deadline).
    var onExpire: (@Sendable () -> Void)?
    /// Largest line accepted (a full frame is base64 PNG).
    static let maxLine = 64 * 1024 * 1024

    init(path: String) {
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    func start(send: Data, onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            self.onLine = onLine
            self.onClose = onClose
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.finish()
                default: break
                }
            }
            connection.start(queue: queue)
            connection.send(content: send, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.finish() }
            })
            receive()
        }
    }

    /// Fails a one-shot request at its deadline.
    func expire() {
        queue.async { [self] in
            let callback = onExpire
            onExpire = nil
            onClose = nil
            onLine = nil
            connection.cancel()
            callback?()
        }
    }

    func cancel() {
        queue.async { [self] in
            onClose = nil
            onLine = nil
            connection.cancel()
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !line.isEmpty { onLine?(Data(line)) }
                }
                if buffer.count > Self.maxLine { buffer.removeAll(); connection.cancel(); return }
            }
            if complete || error != nil {
                finish()
            } else {
                receive()
            }
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let callback = onClose
        onClose = nil
        onLine = nil
        callback?()
    }

    /// Sends one request line and returns the first reply line, or throws
    /// after `deadline`.
    static func oneShot(path: String, send: Data, deadline: Duration) async throws -> Data {
        let connection = AgentActivityLineConnection(path: path)
        let once = OnceBox()
        let timeout = DemandTimer(owner: "agent-activity.request-deadline")
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                connection.onExpire = {
                    continuation.resume(throwing: AgentActivitySourceError.timedOut)
                }
                connection.start(
                    send: send,
                    onLine: { line in
                        if once.claim() { continuation.resume(returning: line) }
                        connection.cancel()
                    },
                    onClose: {
                        if once.claim() { continuation.resume(throwing: AgentActivitySourceError.closed) }
                    })
                timeout.schedule(after: deadline) {
                    if once.claim() { connection.expire() }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// Resumes a continuation exactly once across racing callbacks.
private nonisolated final class OnceBox: Sendable {
    private let done = Mutex(false)

    func claim() -> Bool {
        done.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}
