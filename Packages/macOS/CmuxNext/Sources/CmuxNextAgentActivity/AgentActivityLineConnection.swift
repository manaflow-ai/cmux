public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import struct CmuxSafeConcurrency.OnceContinuationFaultReporter
import func CmuxSafeConcurrency.withOnceThrowingContinuation
import Darwin
import os
public import Foundation
import CmuxNextCompat

/// A line-delimited JSON connection to a Unix socket (the CUA host's
/// framing). All state lives on one private serial queue; callbacks run there
/// and callers hop to their own actor.
///
/// The server check runs on the connection this class writes on (cx-l2ai):
/// connect, read the peer's uid on that descriptor (`LOCAL_PEERCRED`), then
/// send. A separate probe followed by a second connect let a same-uid process
/// swap the socket between the two, and the first frame (with its token)
/// would reach it.
public nonisolated final class AgentActivityLineConnection: @unchecked Sendable { // crash-allow: every mutable field is read and written only on `queue` (one serial queue)
    private let queue = DispatchQueue(label: "cmux.agent-activity.socket", qos: .utility)
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-activity.socket")
    private var descriptor: Int32 = -1
    private var source: (any DispatchSourceRead)?
    private var buffer = Data()
    private var onLine: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var closed = false
    /// Called once by `expire()` (a one-shot request's deadline).
    var onExpire: (@Sendable () -> Void)?
    /// Largest line accepted (a full frame is base64 PNG).
    static let maxLine = 64 * 1024 * 1024
    /// The longest one send may block on a peer that does not read.
    static let sendTimeout = timeval(tv_sec: 10, tv_usec: 0)

    /// Whether the socket's server, read on this connection, may get the
    /// first frame (nil: no check). The CUA clients pass
    /// ``CuaHelperIdentity/isHelperServer(_:)``: this user's process running
    /// the Developer ID signed helper, so an impostor never receives a token.
    let acceptsServer: (@Sendable (UnixSocketPeer) -> Bool)?
    let path: String

    public init(path: String, acceptsServer: (@Sendable (UnixSocketPeer) -> Bool)? = nil) {
        self.path = path
        self.acceptsServer = acceptsServer
    }

    public func start(send: Data, onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            // A `cancel()` queued before this block (a task cancelled as `oneShot` began) already
            // finished the connection; connecting now would leak the descriptor and its read source.
            guard !closed else { return }
            self.onLine = onLine
            self.onClose = onClose
            guard let fd = Self.connect(path: path) else { return finish() }
            descriptor = fd
            // An impostor server must not get the request (or its token): the
            // check is on this very connection, before its first byte.
            if let acceptsServer {
                let peer = UnixSocketPeer(descriptor: fd)
                guard let peer, acceptsServer(peer) else {
                    Self.logger.error("CUA socket \(self.path, privacy: .public): server \(peer?.executablePath ?? "unknown", privacy: .public) is not the signed helper; nothing sent")
                    return finish()
                }
            }
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.readable() }
            reader.setCancelHandler { Darwin.close(fd) }
            source = reader
            reader.resume()
            write(send)
        }
    }

    /// Fails a one-shot request at its deadline; nothing once the connection ended (it answered).
    func expire() {
        queue.async { [self] in
            let callback = closed ? nil : onExpire
            onExpire = nil
            onClose = nil
            onLine = nil
            finish()
            callback?()
        }
    }

    /// Sends another JSON-lines request on a live long-lived connection.
    public func send(_ data: Data) {
        queue.async { [self] in write(data) }
    }

    public func cancel() {
        queue.async { [self] in
            onClose = nil
            onLine = nil
            finish()
        }
    }

    /// ``cancel()`` in the current turn of the queue, for an `onLine` callback (which runs on it) that has
    /// its answer: no later line of the same read, close or deadline of this connection calls back.
    func finishFromCallback() {
        onClose = nil
        onLine = nil
        finish()
    }

    private func write(_ data: Data) {
        guard !closed, descriptor >= 0 else { return }
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.send(descriptor, base + offset, data.count - offset, 0)
            }
            if sent < 0, errno == EINTR { continue }
            guard sent > 0 else { return finish() }
            offset += sent
        }
    }

    private func readable() {
        guard !closed, descriptor >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
        guard count > 0 else {
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            return finish()
        }
        // Only the new bytes can hold a newline: the rest was scanned already.
        var scan = buffer.endIndex
        buffer.append(contentsOf: chunk[0..<count])
        // One pass and one removal per chunk: removing each line from the front
        // moved the rest of the buffer once per line (quadratic in a large chunk).
        var start = buffer.startIndex
        while let newline = buffer[scan...].firstIndex(of: 0x0A) {
            if newline > start { onLine?(Data(buffer[start..<newline])) }
            start = buffer.index(after: newline)
            scan = start
        }
        if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        if buffer.count > Self.maxLine { buffer.removeAll(); finish() }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        // The read source closes the descriptor in its cancel handler, after
        // the source let go of it: closing here could close a descriptor
        // number that another connection already reused. Without a source
        // (a refused or failed start) this closes it.
        if let source {
            source.cancel()
            self.source = nil
        } else if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        descriptor = -1
        let callback = onClose
        onClose = nil
        onLine = nil
        callback?()
    }

    /// A connected unix socket to `path` (blocking, no SIGPIPE, close-on-exec,
    /// a bounded send), or nil when none answers. A local connect is answered
    /// at once.
    static func connect(path: String) -> Int32? {
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
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = sendTimeout
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // concurrency-allow: a local unix socket connect on the connection's own queue, answered at once
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }


    /// Sends one request line and returns the first reply line, or throws
    /// after `deadline`.
    public static func oneShot(path: String, send: Data, deadline: Duration,
                        acceptsServer: (@Sendable (UnixSocketPeer) -> Bool)? = nil) async throws -> Data {
        try await oneShot(path: path, send: send, deadline: deadline, acceptsServer: acceptsServer, faults: .systemLog)
    }

    /// ``oneShot(path:send:deadline:acceptsServer:)`` with the reporter of its continuation's faults (tests).
    ///
    /// Every answer comes from the connection's queue: the first reply line ends the connection in its own
    /// turn (``finishFromCallback()``), and an end or an expiry clears the other callbacks, so exactly one of
    /// line, close and deadline resumes. A cancel answers `CancellationError` at once (`.cancellable`) and
    /// `cancel()` drops the close callback, so the call never waits out its deadline.
    static func oneShot(path: String, send: Data, deadline: Duration,
                        acceptsServer: (@Sendable (UnixSocketPeer) -> Bool)?,
                        faults: OnceContinuationFaultReporter) async throws -> Data {
        let connection = AgentActivityLineConnection(path: path, acceptsServer: acceptsServer)
        let timeout = DemandTimer(owner: "agent-activity.request-deadline")
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withOnceThrowingContinuation(cancellation: .cancellable, faults: faults) {
                (continuation: OnceContinuation<Data, any Error>) in
                connection.onExpire = {
                    continuation.resume(throwing: AgentActivitySourceError.timedOut)
                }
                connection.start(
                    send: send,
                    onLine: { line in
                        continuation.resume(returning: line)
                        connection.finishFromCallback()
                    },
                    onClose: {
                        continuation.resume(throwing: AgentActivitySourceError.closed)
                    })
                timeout.schedule(after: deadline) { connection.expire() }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
