import CmuxNextWakeups
import Darwin
public import Foundation
import Synchronization

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
    /// The event name a `cmux.protocol/2` stream line is routed under
    /// (`DaemonEvent.decode`); the connection opens one stream, `session.events`.
    static let streamEvent = "cmux.protocol/2 stream"

    enum Waiter {
        case reply(cmd: String, ReplySlot)
        case discard(cmd: String, onError: (@Sendable (DaemonError) -> Void)?)
        /// Its deadline passed; the late reply is dropped. The id stays in
        /// `order` so an id-less error still maps to the right request.
        case expired(cmd: String)

        var cmd: String {
            switch self {
            case .reply(let cmd, _), .discard(let cmd, _), .expired(let cmd): cmd
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
        /// Gets resource API stream lines (`stream_item`, `stream_end`).
        var streamHandler: (@Sendable (_ streamID: String, _ line: Data) -> Void)?
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
    func setStreamHandler(_ handler: (@Sendable (_ streamID: String, _ line: Data) -> Void)?) { state.withLock { $0.streamHandler = handler } }

    /// Sends one command and returns the raw `ok:true` response line.
    /// `body` receives the allocated id and returns the encoded JSON object
    /// without the trailing newline. With a `timeout`, a reply that has not
    /// arrived in time fails the request with `DaemonError.timedOut`; the
    /// late reply is dropped when it comes (architecture.md 5a).
    func request(cmd: String, timeout: Duration?, _ body: (UInt64) throws -> Data) async throws -> Response {
        let slot = ReplySlot()
        // A failed submit resolved the slot already.
        guard case .success(let id) = submit(.reply(cmd: cmd, slot), body) else { return try await slot.value() }
        let timer = DemandTimer(owner: "LineTransport.deadline")
        defer { timer.cancel() }
        if let timeout { timer.schedule(after: timeout) { [weak self] in self?.expire(id: id, after: timeout) } }
        return try await slot.value()
    }

    /// Fails a still-pending request with `timedOut`.
    func expire(id: UInt64, after timeout: Duration) {
        let pending: (String, ReplySlot)? = state.withLock { state in
            guard case .reply(let cmd, let slot)? = state.pending[id] else { return nil }
            state.pending[id] = .expired(cmd: cmd)
            return (cmd, slot)
        }
        guard let (cmd, slot) = pending else { return }
        slot.resolve(.failure(DaemonError.timedOut("\(cmd) (no reply within \(timeout))")))
    }

    /// Sends one command without waiting. The response is consumed and
    /// dropped; `onError` sees an `ok:false` answer. Writes reach the socket
    /// in call order.
    func sendNoReply(cmd: String, onError: (@Sendable (DaemonError) -> Void)? = nil, _ body: (UInt64) throws -> Data) throws {
        if case .failure(let error) = submit(.discard(cmd: cmd, onError: onError), body) { throw error }
    }

    /// Writes one line that has no `id` and gets no reply (`loopback-data`
    /// and the other stream lines of `loopback-forward-v1`). Ordered with
    /// every other write. False once the socket failed or closed.
    func sendLine(_ payload: Data) -> Bool {
        socket.withLock { socket in
            guard socket.fd >= 0, state.withLock({ $0.closed == nil }) else { return false }
            var line = payload
            line.append(0x0A)
            return writer.write(line) == nil
        }
    }

    /// Allocates the id, registers the waiter, and writes, all under the
    /// socket lock so `state.order` equals wire order. On failure before
    /// registration the waiter is resumed here; after it, `failAll` owns it.
    /// Returns the request id once the waiter is registered.
    @discardableResult
    func submit(_ waiter: Waiter, _ body: (UInt64) throws -> Data) -> Result<UInt64, any Error> {
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
            writeFailure = socket.fd >= 0 ? writer.write(line)?.description : "socket closed"
            return nil
        }
        if let early {
            if case .reply(_, let slot) = waiter { slot.resolve(.failure(early)) }
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
            case .reply(_, let slot): slot.resolve(.failure(error))
            case .discard, .expired: break
            }
        }
    }

    private func readLoop(fd: Int32, onEvent: EventHandler, onClose: CloseHandler) {
        let decoder = JSONDecoder()
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        var closeDetail = "EOF"
        // wakeup-allow: blocking read on a dedicated thread; EOF, errors and oversize lines end it, EINTR retries
        reading: while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                closeDetail = "read: \(String(cString: strerror(errno)))"
                break
            }
            // Only the new bytes can hold a newline: the buffered rest is one
            // unfinished line. Rescanning it on every read was quadratic in
            // the line size (a 10 MiB replay missed the attach deadline).
            let scanFrom = buffer.count
            buffer.append(contentsOf: chunk[0..<count])
            let lineEnds = Self.newlineOffsets(in: buffer, from: scanFrom)
            var start = 0
            for end in lineEnds {
                if end > start {
                    let base = buffer.startIndex
                    route(Data(buffer[(base + start)..<(base + end)]), decoder: decoder, onEvent: onEvent)
                }
                start = end + 1
            }
            if start > 0 { buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + start)) }
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

    /// Offsets (from `data.startIndex`) of every newline at or after `offset`.
    static func newlineOffsets(in data: Data, from offset: Int) -> [Int] {
        data.withUnsafeBytes { raw -> [Int] in
            guard let base = raw.baseAddress, offset < raw.count else { return [] }
            var offsets: [Int] = []
            var position = offset
            while position < raw.count, let hit = memchr(base + position, 0x0A, raw.count - position) {
                let found = base.distance(to: UnsafeRawPointer(hit))
                offsets.append(found)
                position = found + 1
            }
            return offsets
        }
    }

    /// Events routed so far. Read after a command's reply, it bounds every
    /// event the daemon emitted before that reply (a write barrier).
    var routedEventCount: UInt64 { state.withLock { $0.eventCount } }

    private func route(_ line: Data, decoder: JSONDecoder, onEvent: EventHandler) {
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else { return }
        // A v2 stream line goes to the stream handler of a dedicated
        // connection (`SessionJournalRead`); on the control connection it
        // travels with the raw events, in socket order (`session.events`).
        let streamed = envelope.type == "stream_item" || envelope.type == "stream_end"
        if streamed, let streamID = envelope.streamID, let handler = state.withLock({ $0.streamHandler }) {
            return handler(streamID, line)
        }
        if let name = streamed ? Self.streamEvent : envelope.event {
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
            if case .reply(_, let slot) = waiter { slot.resolve(.success(Response(line: line, eventBarrier: barrier))) }
            return
        }
        let error = DaemonError.command(cmd: waiter.cmd, message: envelope.error ?? "unknown error", code: envelope.errorCode,
                                        details: envelope.errorDetails, retryable: envelope.retryable)
        switch waiter {
        case .reply(_, let slot): slot.resolve(.failure(error))
        case .discard(_, let onError): onError?(error)
        case .expired: break
        }
    }
}
