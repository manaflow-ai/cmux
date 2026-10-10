import CmuxNextWakeups
import Darwin
public import Foundation
import Network
import Synchronization

/// A line-delimited JSON connection to a Unix socket (the CUA host's
/// framing). All state lives on one private serial queue; callbacks run there
/// and callers hop to their own actor.
public nonisolated final class AgentActivityLineConnection: @unchecked Sendable {
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

    /// The uid the socket's server must run as before anything is sent
    /// (nil: no check). The CUA helper's clients pass this user's uid, so an
    /// impostor server never receives a token.
    let expectedServerUID: uid_t?
    let path: String

    public init(path: String, expectedServerUID: uid_t? = nil) {
        self.path = path
        self.expectedServerUID = expectedServerUID
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    public func start(send: Data, onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            self.onLine = onLine
            self.onClose = onClose
            // An impostor server must not get the request (or its token).
            if let expectedServerUID, Self.serverUID(path: path) != expectedServerUID {
                return finish()
            }
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

    /// Sends another JSON-lines request on a live long-lived connection.
    public func send(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.finish() }
            })
        }
    }

    public func cancel() {
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

    /// The uid the server listening on the Unix socket at `path` runs as
    /// (LOCAL_PEERCRED), or nil when none answers. A non-blocking local
    /// connect, answered at once; nothing is sent.
    static func serverUID(path: String) -> uid_t? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // concurrency-allow: O_NONBLOCK local connect, answered at once and never waits on the server
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0,
              credentials.cr_version == XUCRED_VERSION else { return nil }
        return credentials.cr_uid
    }

    /// Sends one request line and returns the first reply line, or throws
    /// after `deadline`.
    static func oneShot(path: String, send: Data, deadline: Duration, expectedServerUID: uid_t? = nil) async throws -> Data {
        let connection = AgentActivityLineConnection(path: path, expectedServerUID: expectedServerUID)
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
