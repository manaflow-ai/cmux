import CmuxNextWakeups
import Darwin
public import Foundation
import CmuxNextCompat

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

    /// One message of a client attach stream (`attach-streams-v1`), delivered on
    /// the reader thread in wire order.
    enum StreamMessage: Sendable {
        /// A binary frame other than EVENT and RING (`attach-frames-v1`).
        case frame(AttachFrameHeader, Data)
        /// A RING frame and the ring's read-only descriptor that rode on it;
        /// the sink owns the descriptor (`terminal-output-ring-v1`).
        case ring(AttachFrameHeader, Data, descriptor: Int32)
        /// One JSON event of the stream: an EVENT frame's object, or a JSON
        /// line tagged with the stream. `stream-end` is the stream's last one.
        case event(name: String, line: Data)
        /// The connection ended; no message follows.
        case closed(TransportCloseReason)
    }

    /// Receives one stream's messages on the reader thread. It must not block:
    /// every stream and the control plane share the reader.
    typealias StreamSink = @Sendable (StreamMessage) -> Void

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
        /// Open client attach streams by id, until their `stream-end` or the
        /// connection's end.
        var attachStreams: [UInt16: StreamSink] = [:]
        /// The next id to try when minting one.
        var nextAttachStream: UInt16 = 1
        /// Messages for a stream id that is not open (a contract drift).
        var strayStreamMessages: UInt64 = 0

        /// Mints an id no open stream holds and registers `sink` under it.
        mutating func openAttachStream(_ sink: @escaping StreamSink) -> UInt16? {
            guard closed == nil else { return nil }
            // At most one pass over the 65,535 ids: nil when every one is open.
            for _ in 0..<0xFFFF {
                let id = nextAttachStream
                nextAttachStream = id == UInt16.max ? 1 : id + 1
                if attachStreams[id] == nil {
                    attachStreams[id] = sink
                    return id
                }
            }
            return nil
        }

        /// The open stream `id`'s sink; taken out when `removing` (its end).
        mutating func attachSink(_ id: UInt16, removing: Bool) -> StreamSink? {
            removing ? attachStreams.removeValue(forKey: id) : attachStreams[id]
        }

        /// Marks a pending reply expired; its command and slot, or nil when
        /// `id` is not waiting for a reply.
        mutating func expireReply(_ id: UInt64) -> (String, ReplySlot)? {
            guard case .reply(let cmd, let slot)? = pending[id] else { return nil }
            pending.updateValue(.expired(cmd: cmd), forKey: id)
            return (cmd, slot)
        }

        /// Every pending waiter, in send order.
        func waitersInSendOrder() -> [Waiter] {
            order.compactMap { pending[$0] }
        }
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

    /// The bridge child of this connection (``DaemonBridge``), killed and
    /// reaped when the connection closes.
    private let child: BridgeChild?

    init(path: String, bridge: DaemonBridge? = nil) throws(DaemonError) {
        self.path = path
        let fd: Int32
        if let bridge {
            let opened = try bridge.open()
            fd = opened.fd
            child = opened.child
        } else {
            fd = try Self.connect(path)
            child = nil
        }
        socket = Mutex(Socket(fd: fd))
        writer = SocketWriter(fd: fd, label: "com.cmuxterm.next.daemon.write")
    }

    /// A transport over an already connected socket `fd`, which it owns
    /// (tests: one end of a `socketpair`; `path` only names it).
    init(connected fd: Int32, path: String) {
        self.path = path
        child = nil
        socket = Mutex(Socket(fd: fd))
        writer = SocketWriter(fd: fd, label: "com.cmuxterm.next.daemon.write")
    }

    private static func connect(_ path: String) throws(DaemonError) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .connectFailed(path: path, errno: errno) }
        // Close-on-exec: a program the app execs must not inherit a daemon connection, whose
        // peer key is this process's audit token (request-origin.md, peer key caveat).
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
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
        withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
            var raw = sunPath  // the same memory; `modify` is mutating on the view
            raw.copyBytes(from: pathBytes)
            raw.modify(checked: pathBytes.count) { $0 = 0 }
        }
        address.sun_len = UInt8(clamping: MemoryLayout<sockaddr_un>.size) // 106 bytes
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
        return fd
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

    /// Opens a client attach stream: mints its id and registers `sink`
    /// before any request names it, so the messages that precede the attach
    /// reply (the READY) are routed. Nil once the transport closed.
    func openStream(_ sink: @escaping StreamSink) -> UInt16? {
        state.withLock { $0.openAttachStream(sink) }
    }

    /// Forgets a stream whose attach request failed before the daemon opened
    /// it (the daemon then sends nothing for the id). A stream the daemon
    /// opened is forgotten at its `stream-end`.
    func forgetStream(_ id: UInt16) {
        _ = state.withLock { $0.attachStreams.removeValue(forKey: id) }
    }

    /// Messages that named a stream id not open (diagnostics, tests).
    var strayStreamMessages: UInt64 { state.withLock { $0.strayStreamMessages } }
    func setStreamHandler(_ handler: (@Sendable (_ streamID: String, _ line: Data) -> Void)?) { state.withLock { $0.streamHandler = handler } }

    /// Sends one command and returns the raw `ok:true` response line.
    /// `body` receives the allocated id and returns the encoded JSON object
    /// without the trailing newline. With a `timeout`, a reply that has not
    /// arrived in time fails the request with `DaemonError.timedOut`; the
    /// late reply is dropped when it comes (architecture.md 5a).
    func request(cmd: String, timeout: Duration?, _ body: (UInt64) throws -> Data) async throws -> Response {
        let slot = ReplySlot()
        #if DEBUG
        // A traced new terminal: the request naming its id, and that request's reply.
        var traced: String?
        let submitted: Result<UInt64, any Error>
        if NewTerminalTrace.shared.isArmed {
            submitted = submit(.reply(cmd: cmd, slot), { id in
                let line = try body(id)
                traced = NewTerminalTrace.shared.requestSent(line)
                return line
            })
        } else {
            submitted = submit(.reply(cmd: cmd, slot), body)
        }
        #else
        let submitted = submit(.reply(cmd: cmd, slot), body)
        #endif
        // A failed submit resolved the slot already.
        guard case .success(let id) = submitted else { return try await slot.value() }
        let timer = DemandTimer(owner: "LineTransport.deadline")
        defer { timer.cancel() }
        if let timeout { timer.schedule(after: timeout) { [weak self] in self?.expire(id: id, after: timeout) } }
        #if DEBUG
        let response = try await slot.value()
        if let traced { NewTerminalTrace.shared.mark(.reply, terminal: traced) }
        return response
        #else
        return try await slot.value()
        #endif
    }

    /// Fails a still-pending request with `timedOut`.
    func expire(id: UInt64, after timeout: Duration) {
        let expired: (String, ReplySlot)? = state.withLock { state in state.expireReply(id) }
        guard let (cmd, slot) = expired else { return }
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
                state.pending.updateValue(waiter, forKey: id)
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
        child?.terminate()
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
        let (waiters, streams): ([Waiter], [StreamSink]) = state.withLock { state in
            if state.closed == nil { state.closed = reason }
            let waiters = state.waitersInSendOrder()
            state.pending.removeAll()
            state.order.removeAll()
            let streams = Array(state.attachStreams.values)
            state.attachStreams.removeAll()
            return (waiters, streams)
        }
        let closedReason = state.withLock { $0.closed } ?? reason
        for sink in streams { sink(.closed(closedReason)) }
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
        var messages = WireSplitter()
        var received = SocketDescriptorReader()
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        var closeDetail = "EOF"
        // wakeup-allow: blocking read on a dedicated thread; EOF, errors and oversize lines end it, EINTR retries
        reading: while true {
            let count = chunk.withUnsafeMutableBytes { received.read(fd, into: $0) }
            if received.truncated {
                closeDetail = "the daemon passed more descriptors than one read holds"
                break
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                closeDetail = "read: \(String(cString: strerror(errno)))"
                break
            }
            var missingDescriptor = false
            do {
                try chunk.withUnsafeBytes { raw in
                    try messages.append(UnsafeRawBufferPointer(rebasing: raw.prefix(count))) { message in
                        switch message {
                        case .line(let line): route(line, decoder: decoder, onEvent: onEvent)
                        case .frame(let header, let payload) where header.kind == .ring:
                            // A RING frame takes the descriptor that rode on it.
                            guard let descriptor = received.take() else {
                                missingDescriptor = true
                                return
                            }
                            deliverRing(header, payload, descriptor: descriptor)
                        case .frame(let header, let payload): routeFrame(header, payload, decoder: decoder)
                        }
                    }
                }
            } catch {
                closeDetail = "bad frame: \(error)"
                break reading
            }
            if missingDescriptor {
                closeDetail = "a RING frame came without its descriptor"
                break reading
            }
            if messages.bufferedBytes > Self.maxLineBytes {
                closeDetail = "message exceeds \(Self.maxLineBytes) bytes"
                break reading
            }
        }
        let reason: TransportCloseReason = state.withLock { state in
            if let closed = state.closed { return closed }
            return state.sawShutdown ? .daemonShutdown : .lost(closeDetail)
        }
        received.closeAll()
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

    /// Hands a RING frame and its descriptor to its stream, which owns the
    /// descriptor from then on; a stream that is not open gets none, and the
    /// descriptor is closed here.
    private func deliverRing(_ header: AttachFrameHeader, _ payload: Data, descriptor: Int32) {
        let sink: StreamSink? = state.withLock { state in
            let sink = state.attachSink(header.stream, removing: false)
            if sink == nil { state.strayStreamMessages += 1 }
            return sink
        }
        guard let sink else {
            Darwin.close(descriptor)
            return
        }
        sink(.ring(header, payload, descriptor: descriptor))
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
        if !streamed, let stream = envelope.attachStream, let name = envelope.event {
            return deliver(stream: stream, .event(name: name, line: line))
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

    /// Routes one frame to its stream; an EVENT frame as the stream's event.
    private func routeFrame(_ header: AttachFrameHeader, _ payload: Data, decoder: JSONDecoder) {
        guard header.kind == .event else { return deliver(stream: header.stream, .frame(header, payload)) }
        guard let name = (try? decoder.decode(Envelope.self, from: payload))?.event else {
            state.withLock { $0.strayStreamMessages += 1 }
            return
        }
        deliver(stream: header.stream, .event(name: name, line: payload))
    }

    /// Hands `message` to the open stream `id`; after its `stream-end` the id
    /// is free again.
    private func deliver(stream id: UInt16, _ message: StreamMessage) {
        var ends = false
        if case .event(let name, _) = message, name == "stream-end" { ends = true }
        let sink: StreamSink? = state.withLock { state in
            let sink = state.attachSink(id, removing: ends)
            if sink == nil { state.strayStreamMessages += 1 }
            return sink
        }
        sink?(message)
    }
}
