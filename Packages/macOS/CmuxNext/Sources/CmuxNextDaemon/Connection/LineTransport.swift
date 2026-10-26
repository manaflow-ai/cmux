import CmuxNextWakeups
import Darwin
public import Foundation
import CmuxNextCompat
import CmuxNextTrace

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
    /// How long the reader may take to handle one line (decode and route it) before the hang watcher
    /// reports it: a line is a few microseconds, so 100 ms means the reader thread is stuck.
    static let lineHangDeadline: Duration = .milliseconds(100)

    private struct State {
        var nextID: UInt64 = 1
        var pending: [UInt64: Waiter] = [:]
        /// Request ids in send order, for id-less error responses.
        var order: [UInt64] = []
        var closed: TransportCloseReason?
        var sawShutdown = false
        /// Stream-0 events routed so far (raw events and `controlStreams`
        /// lines); responses capture it as their barrier.
        var eventCount: UInt64 = 0
        /// Streams the daemon writes in its reply FIFO (`session.events`).
        var controlStreams: Set<String> = []
        /// Gets resource API stream lines (`stream_item`, `stream_end`).
        var streamHandler: (@Sendable (_ streamID: String, _ line: Data) -> Void)?

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
        /// The connection's recorder: decoding the line counts there
        /// (`WireCoding.decodeResponse(_:from:)` given the response).
        var recorder: DaemonWireStats.Recorder?
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
    /// Why this connection exists, for ``recorder``.
    let role: DaemonWireStats.Role
    /// Where this connection's traffic is counted (lock-free; the reader thread records too); nil
    /// counts nothing (a release build).
    let recorder: DaemonWireStats.Recorder?
    /// Decodes this connection's lines on its reader thread, counting into ``recorder``; event
    /// handlers, which run there, decode with it too.
    let decoder: WireDecoder
    /// Watches the reader's handling of each line, never its wait in `read(2)`; nil watches nothing.
    private let hangWatched: HangWatchedLane?
    /// Where each request's `daemon.request` slice goes (LineTransport+RequestTrace.swift), the top bits of its
    /// async id (``traceConnectionBits(scope:)``) and its flow's seed (``requestFlowSeed(pid:)``).
    let trace: TraceRuntime, traceConnection: UInt64, traceFlowSeed: UInt64

    /// - Parameter stats: Where the connection counts (``DaemonEndpoint/wireStats``); nil for none.
    /// - Parameter hangs: Watches each line's handling on the reader thread; nil watches nothing.
    init(path: String, bridge: DaemonBridge? = nil, role: DaemonWireStats.Role,
         stats: DaemonWireStats?, hangs: (any HangWatchScoping)? = nil, trace: TraceRuntime = .shared) throws(DaemonError) {
        self.path = path
        self.role = role
        self.trace = trace
        traceConnection = Self.traceConnectionBits(scope: trace.nextAsyncScope())
        traceFlowSeed = Self.requestFlowSeed(pid: getpid())
        let recorder = stats?.recorder()
        self.recorder = recorder
        decoder = WireCoding.decoder(recorder)
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
        writer = SocketWriter(fd: fd, label: "com.cmuxterm.next.daemon.write", qos: role.writerQoS)
        recorder?.connectionOpened(role, bridged: bridge != nil)
        // After the last throw: a transport that never opened registers nothing (its deinit does not run).
        hangWatched = hangs.map { HangWatchedLane("daemon.line", deadline: Self.lineHangDeadline, on: $0) }
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
        hangWatched?.unregister()
        writer.close()
        closeDescriptor()
    }

    /// Closes the descriptor once (the reader's exit or deinit, whichever comes first) and counts
    /// the connection closed.
    private func closeDescriptor() {
        let closed = socket.withLock { socket -> Bool in
            guard socket.fd >= 0 else { return false }
            Darwin.close(socket.fd)
            socket.fd = -1
            return true
        }
        if closed { recorder?.connectionClosed(role) }
    }

    /// Starts the reader thread, handing each event its envelope cause. Call once.
    func start(onCausedEvent onEvent: @escaping CausedEventHandler, onClose: @escaping CloseHandler) {
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

    /// Counts `streamID`'s lines as stream-0 events until its `stream_end`;
    /// call before the request that opens it, `endControlSequence` if that fails.
    func routeOnControlSequence(streamID: String) { _ = state.withLock { $0.controlStreams.insert(streamID) } }
    func endControlSequence(streamID: String) { _ = state.withLock { $0.controlStreams.remove(streamID) } }

    /// Sends one command and returns the raw `ok:true` response line.
    /// `body` receives the allocated id and returns the encoded JSON object
    /// without the trailing newline. With a `timeout`, a reply that has not
    /// arrived in time fails the request with `DaemonError.timedOut`; the
    /// late reply is dropped when it comes (architecture.md 5a). Its
    /// `daemon.request` slice ends when the slot resolves (LineTransport+RequestTrace.swift).
    func request(cmd: DaemonCommandName, timeout: Duration?, _ body: (UInt64) throws -> Data) async throws -> Response {
        let slot = ReplySlot()
        #if DEBUG || CMUX_BENCH_HOOKS
        // A traced new terminal: the request naming its id, and that request's reply.
        let armed = NewTerminalTrace.shared.isArmed
        var traced: String?
        #endif
        let submitted = submit(.reply(cmd: cmd.wire, slot)) { id in
            let line = try body(id)
            #if DEBUG || CMUX_BENCH_HOOKS
            if armed { traced = NewTerminalTrace.shared.requestSent(line) }
            #endif
            beginRequestSpan(cmd, id: id, slot: slot)
            return line
        }
        // A failed submit resolved the slot already.
        guard case .success(let id) = submitted else { return try await slot.value() }
        let timer = DemandTimer(owner: "LineTransport.deadline")
        defer { timer.cancel() }
        if let timeout { timer.schedule(after: timeout) { [weak self] in self?.expire(id: id, after: timeout) } }
        let response = try await slot.value()
        #if DEBUG || CMUX_BENCH_HOOKS
        if let traced { NewTerminalTrace.shared.mark(.reply, terminal: traced) }
        #endif
        return response
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
            guard writer.write(line) == nil else { return false }
            recorder?.lineWritten(bytes: line.count)
            return true
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
            if writeFailure == nil { recorder?.lineWritten(bytes: line.count) }
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
        let waiters: [Waiter] = state.withLock { state in
            if state.closed == nil { state.closed = reason }
            let waiters = state.waitersInSendOrder()
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

    private func readLoop(fd: Int32, onEvent: CausedEventHandler, onClose: CloseHandler) {
        let decoder = self.decoder
        let recorder = self.recorder
        // An attach connection carries the terminal's output: the splitter's copies of its bytes
        // are copies of that output (``DaemonWireStats/Snapshot/outputBytesCopiedApp``).
        let outputStream = role == .terminalAttach ? recorder : nil
        var lines = LineSplitter()
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        var closeDetail = "EOF"
        // wakeup-allow: bounded: blocking read on a dedicated thread; EOF, errors and oversize lines end it, EINTR retries
        reading: while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                closeDetail = "read: \(String(cString: strerror(errno)))"
                break
            }
            recorder?.bytesRead(count)
            outputStream?.outputCopied(count)  // into the splitter's buffer
            lines.append(chunk.prefix(count)) { line in
                outputStream?.outputCopied(line.count)  // out of it, as the line
                handle(line, decoder: decoder, onEvent: onEvent)
            }
            if lines.pending.count > Self.maxLineBytes {
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
        closeDescriptor()
        onClose(reason)
    }

    /// Stream-0 events routed so far; a reply captures it as its barrier.
    /// After p05-ipc-120 it bounds every event the daemon emitted before that
    /// reply (cmux-tui/spec/transports.md "Reply and event order", rule 2).
    /// Until then the daemon's subscription hop can write the reply before
    /// the request's own events, so the barrier can miss them.
    var routedEventCount: UInt64 { state.withLock { $0.eventCount } }

    /// Routes one line inside a hang scope of ``lineHangDeadline`` (Chrome watches each IO-thread task
    /// the same way, base/threading/hang_watcher.cc).
    private func handle(_ line: Data, decoder: WireDecoder, onEvent: CausedEventHandler) {
        guard let hangWatched else { return route(line, decoder: decoder, onEvent: onEvent) }
        hangWatched.run { route(line, decoder: decoder, onEvent: onEvent) }
    }

    private func route(_ line: Data, decoder: WireDecoder, onEvent: CausedEventHandler) {
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else {
            recorder?.lineRead(.ignored)
            return
        }
        // A v2 stream line goes to the stream handler of a dedicated
        // connection (`SessionJournalRead`); on the control connection it
        // travels with the raw events, in socket order (`session.events`).
        let streamed = envelope.type == "stream_item" || envelope.type == "stream_end"
        let streamKind: DaemonWireStats.FrameKind = envelope.type == "stream_end" ? .streamEnd : .streamItem
        if streamed, let streamID = envelope.streamID {
            let streamRoute = state.withLock { state -> StreamRoute in
                if state.controlStreams.contains(streamID) {
                    if envelope.type == "stream_end" { state.controlStreams.remove(streamID) }
                    return .control
                }
                if let handler = state.streamHandler { return .handler(handler) }
                return .unrouted
            }
            switch streamRoute {
            case .control: break
            case .handler(let handler):
                recorder?.lineRead(streamKind)
                return handler(streamID, line)
            case .unrouted:
                recorder?.lineRead(.ignored)
                return
            }
        }
        if let name = streamed ? Self.streamEvent : envelope.event {
            let index = state.withLock { state -> UInt64 in
                if name == "daemon-shutdown" { state.sawShutdown = true }
                state.eventCount += 1
                return state.eventCount
            }
            recorder?.lineRead(streamed ? streamKind : .event)
            onEvent(name, line, index, envelope.cause)
            return
        }
        guard envelope.ok != nil || envelope.id != nil else {
            recorder?.lineRead(.ignored)
            return
        }
        let waiter: (UInt64, Waiter)? = state.withLock { state in
            let id = envelope.id ?? state.order.first
            guard let id, let waiter = state.pending.removeValue(forKey: id) else { return nil }
            state.order.removeAll { $0 == id }
            return (state.eventCount, waiter)
        }
        guard let (barrier, waiter) = waiter else {
            recorder?.lineRead(.droppedReply)
            return
        }
        recorder?.lineRead(waiter.replyKind(ok: envelope.ok == true))
        if envelope.ok == true {
            if case .reply(_, let slot) = waiter {
                slot.resolve(.success(Response(line: line, eventBarrier: barrier, recorder: recorder)))
            }
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
