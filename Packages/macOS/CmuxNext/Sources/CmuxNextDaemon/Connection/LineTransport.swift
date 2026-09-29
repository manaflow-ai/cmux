import Darwin
public import Foundation
import Synchronization

/// Holds one request's deadline task so the request cancels it on return.
final class DeadlineTimer: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let cancelled = Mutex(false)

    func start(_ body: @escaping @Sendable () async -> Void) {
        let started = Task { await body() }
        let isCancelled = cancelled.withLock { $0 }
        if isCancelled {
            started.cancel()
        } else {
            task.withLock { $0 = started }
        }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        task.withLock { $0?.cancel() }
    }
}

/// Why a transport stopped.
public enum TransportCloseReason: Sendable, Equatable {
    /// `close()` was called locally.
    case closedByClient
    /// The daemon sent `daemon-shutdown`, then EOF.
    case daemonShutdown
    /// EOF or a read/write error.
    case lost(String)
}

/// One JSON Lines connection to a cmux-tui Unix socket (raw protocol v12).
///
/// A dedicated reader thread splits lines and routes them without touching
/// any actor: responses resume their waiter by `id` (FIFO fallback for the
/// id-less `bad request` envelope, which is safe because commands start
/// serially per connection), and events go to `onEvent` on the reader thread.
/// The server drops slow readers (4,096-event mailbox, 2 s write deadline),
/// so the reader never blocks on the main actor.
final class LineTransport: Sendable {
    /// `index` counts events on this transport from 1, in wire order.
    typealias EventHandler = @Sendable (_ name: String, _ line: Data, _ index: UInt64) -> Void
    typealias CloseHandler = @Sendable (TransportCloseReason) -> Void

    /// Inbound limit: the server may send up to 32 MiB (VT replay).
    static let maxLineBytes = 64 << 20

    private enum Waiter {
        case continuation(cmd: String, CheckedContinuation<Response, any Error>)
        case discard(cmd: String, onError: (@Sendable (DaemonError) -> Void)?)
        /// Its deadline passed; the late reply is dropped. The id stays in
        /// `order` so an id-less error still maps to the right request.
        case expired(cmd: String)

        var cmd: String {
            switch self {
            case .continuation(let cmd, _), .discard(let cmd, _), .expired(let cmd): cmd
            }
        }
    }

    private struct State {
        var nextID: UInt64 = 1
        var pending: [UInt64: Waiter] = [:]
        /// Request ids in send order, for id-less error responses.
        var order: [UInt64] = []
        var closed: TransportCloseReason?
        var sawShutdown = false
        /// Events routed so far; responses capture it as their barrier.
        var eventCount: UInt64 = 0
    }

    /// An `ok:true` response line plus the number of events routed before it
    /// on this transport. Every event with index <= `eventBarrier` was
    /// emitted before the command's result, so a snapshot supersedes it.
    struct Response: Sendable {
        var line: Data
        var eventBarrier: UInt64
    }

    /// Guards the descriptor: writes and close are serialized so a write never
    /// lands on a reused fd.
    private struct Socket {
        var fd: Int32
    }

    private let state = Mutex(State())
    private let socket: Mutex<Socket>
    /// Nonblocking, ordered writes (never parks the calling actor's thread).
    private let writer: SocketWriter
    let path: String

    init(path: String) throws(DaemonError) {
        self.path = path
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .connectFailed(path: path, errno: errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(fd)
            throw .socketPathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw .connectFailed(path: path, errno: code)
        }
        socket = Mutex(Socket(fd: fd))
        writer = SocketWriter(fd: fd, label: "com.cmuxterm.next.daemon.write")
    }

    deinit {
        writer.close()
        socket.withLock { socket in
            if socket.fd >= 0 {
                Darwin.close(socket.fd)
                socket.fd = -1
            }
        }
    }

    /// Starts the reader thread. Call once.
    func start(onEvent: @escaping EventHandler, onClose: @escaping CloseHandler) {
        let fd = socket.withLock { $0.fd }
        let thread = Thread { [self] in
            readLoop(fd: fd, onEvent: onEvent, onClose: onClose)
        }
        thread.name = "cmux-tui reader \(path)"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    var isClosed: Bool { state.withLock { $0.closed != nil } }

    /// Sends one command and returns the raw `ok:true` response line.
    /// `body` receives the allocated id and returns the encoded JSON object
    /// without the trailing newline. With a `timeout`, a reply that has not
    /// arrived in time fails the request with `DaemonError.timedOut`; the
    /// late reply is dropped when it comes (architecture.md 5a).
    func request(cmd: String, timeout: Duration?, _ body: (UInt64) throws -> Data) async throws -> Response {
        let timer = DeadlineTimer()
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            guard case .success(let id) = submit(.continuation(cmd: cmd, continuation), body), let timeout else { return }
            timer.start { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.expire(id: id, after: timeout)
            }
        }
    }

    /// Fails a still-pending request with `timedOut`.
    private func expire(id: UInt64, after timeout: Duration) {
        let continuation: (String, CheckedContinuation<Response, any Error>)? = state.withLock { state in
            guard case .continuation(let cmd, let continuation)? = state.pending[id] else { return nil }
            state.pending[id] = .expired(cmd: cmd)
            return (cmd, continuation)
        }
        guard let (cmd, continuation) = continuation else { return }
        continuation.resume(throwing: DaemonError.timedOut("\(cmd) (no reply within \(timeout))"))
    }

    /// Sends one command without waiting. The response is consumed and
    /// dropped; `onError` sees an `ok:false` answer. Writes reach the socket
    /// in call order.
    func sendNoReply(cmd: String, onError: (@Sendable (DaemonError) -> Void)? = nil, _ body: (UInt64) throws -> Data) throws {
        if case .failure(let error) = submit(.discard(cmd: cmd, onError: onError), body) { throw error }
    }

    /// Allocates the id, registers the waiter, and writes, all under the
    /// socket lock so `state.order` equals wire order. On failure before
    /// registration the waiter is resumed here; after it, `failAll` owns it.
    /// Returns the request id once the waiter is registered.
    @discardableResult
    private func submit(_ waiter: Waiter, _ body: (UInt64) throws -> Data) -> Result<UInt64, any Error> {
        var writeFailure: String?
        var submittedID: UInt64 = 0
        let early: (any Error)? = socket.withLock { socket -> (any Error)? in
            let id: UInt64
            switch state.withLock({ state -> Result<UInt64, DaemonError> in
                if let reason = state.closed { return .failure(Self.closedError(reason)) }
                defer { state.nextID += 1 }
                return .success(state.nextID)
            }) {
            case .success(let value): id = value
            case .failure(let error): return error
            }
            let payload: Data
            do { payload = try body(id) } catch { return error }
            state.withLock { state in
                state.pending[id] = waiter
                state.order.append(id)
            }
            submittedID = id
            var line = payload
            line.append(0x0A)
            writeFailure = socket.fd >= 0 ? writer.write(line) : "socket closed"
            return nil
        }
        if let early {
            if case .continuation(_, let continuation) = waiter { continuation.resume(throwing: early) }
            return .failure(early)
        }
        if let writeFailure {
            failAll(.lost(writeFailure))
            return .failure(DaemonError.connectionClosed(reason: writeFailure))
        }
        return .success(submittedID)
    }

    /// Closes the socket; pending requests fail with `.connectionClosed`.
    func close() {
        failAll(.closedByClient)
        socket.withLock { socket in
            if socket.fd >= 0 { Darwin.shutdown(socket.fd, SHUT_RDWR) }
        }
    }

    // MARK: - Private

    private static func closedError(_ reason: TransportCloseReason) -> DaemonError {
        switch reason {
        case .closedByClient: .connectionClosed(reason: "closed by client")
        case .daemonShutdown: .daemonShutdown
        case .lost(let detail): .connectionClosed(reason: detail)
        }
    }

    private func failAll(_ reason: TransportCloseReason) {
        let waiters: [Waiter] = state.withLock { state in
            if state.closed == nil { state.closed = reason }
            let waiters = state.order.compactMap { state.pending[$0] }
            state.pending.removeAll()
            state.order.removeAll()
            return waiters
        }
        let error = Self.closedError(reason)
        for waiter in waiters {
            switch waiter {
            case .continuation(_, let continuation): continuation.resume(throwing: error)
            case .discard, .expired: break
            }
        }
    }

    private struct Envelope: Decodable {
        var id: UInt64?
        var ok: Bool?
        var event: String?
        var error: String?
        var errorCode: String?

        enum CodingKeys: String, CodingKey {
            case id, ok, event, error
            case errorCode = "error_code"
        }
    }

    private func readLoop(fd: Int32, onEvent: EventHandler, onClose: CloseHandler) {
        let decoder = JSONDecoder()
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        var closeDetail = "EOF"
        reading: while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                closeDetail = "read: \(String(cString: strerror(errno)))"
                break
            }
            buffer.append(contentsOf: chunk[0..<count])
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                let line = buffer[start..<newline]
                start = buffer.index(after: newline)
                if !line.isEmpty { route(Data(line), decoder: decoder, onEvent: onEvent) }
            }
            buffer.removeSubrange(buffer.startIndex..<start)
            if buffer.count > Self.maxLineBytes {
                closeDetail = "line exceeds \(Self.maxLineBytes) bytes"
                break reading
            }
        }
        let reason: TransportCloseReason = state.withLock { state in
            if let closed = state.closed { return closed }
            return state.sawShutdown ? .daemonShutdown : .lost(closeDetail)
        }
        failAll(reason)
        writer.close()
        socket.withLock { socket in
            if socket.fd >= 0 {
                Darwin.close(socket.fd)
                socket.fd = -1
            }
        }
        onClose(reason)
    }

    private func route(_ line: Data, decoder: JSONDecoder, onEvent: EventHandler) {
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else { return }
        if let name = envelope.event {
            let index = state.withLock { state -> UInt64 in
                if name == "daemon-shutdown" { state.sawShutdown = true }
                state.eventCount += 1
                return state.eventCount
            }
            onEvent(name, line, index)
            return
        }
        guard envelope.ok != nil || envelope.id != nil else { return }
        let waiter: (UInt64, Waiter)? = state.withLock { state in
            let id = envelope.id ?? state.order.first
            guard let id, let waiter = state.pending.removeValue(forKey: id) else { return nil }
            state.order.removeAll { $0 == id }
            return (state.eventCount, waiter)
        }
        guard let (barrier, waiter) = waiter else { return }
        if envelope.ok == true {
            if case .continuation(_, let continuation) = waiter {
                continuation.resume(returning: Response(line: line, eventBarrier: barrier))
            }
            return
        }
        let error = DaemonError.command(cmd: waiter.cmd, message: envelope.error ?? "unknown error", code: envelope.errorCode)
        switch waiter {
        case .continuation(_, let continuation): continuation.resume(throwing: error)
        case .discard(_, let onError): onError?(error)
        case .expired: break
        }
    }
}
