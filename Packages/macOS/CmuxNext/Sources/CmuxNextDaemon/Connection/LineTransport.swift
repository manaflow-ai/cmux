import CmuxNextWakeups
import Darwin
public import Foundation
import CmuxNextCompat
import CmuxNextIPC
import CmuxNextTrace

/// Why a transport stopped.
public enum TransportCloseReason: Sendable, Equatable {
    /// `close()` was called locally.
    case closedByClient
    /// The daemon sent `daemon-shutdown`, then EOF.
    case daemonShutdown
    /// EOF, a read/write error, or a bad message.
    case lost(String)
}

/// One connection to a cmux-tui Unix socket (raw protocol v12): the app's DaemonTransport.
///
/// A dedicated reader thread cuts messages with CmuxNextIPC's ``FrameReader`` and routes them without
/// touching any actor or decoding them (p05-ipc-144): responses resume their waiter by `id` (the oldest pending
/// request for the id-less `bad request` envelope, which is safe because commands start serially per
/// connection), and events go to `onEvent` through the connection's ``DecodeLane``, the one FIFO of its replies
/// and events: a heavy event (a control event's decode, a snapshot inflate) runs on the lane's serial queue, a
/// light one or a reply inline while the lane is idle. A line is routed by fields read from its bytes
/// (``LineRouteScan``), so the one JSON parse of a reply or an event is its reader's. Waiters are a dictionary
/// plus an id ring (``PendingRequests``), O(1) per request. Reply deadlines are one heap (``DeadlineHeap``) under one
/// ``DemandTimer`` per connection, as a Chrome sequence keeps its delayed tasks under one wake-up
/// (base/task/sequence_manager/wake_up_queue.cc). Writes go through ``SocketWriter`` (CmuxNextIPC's `FrameWriter`).
/// The socket buffers are ``socketBufferBytes`` each way, the daemon's value. The server drops slow readers
/// (4,096-event mailbox, 2 s write deadline), so the reader never blocks on the main actor; it waits only while
/// its lane's backlog or a bounded consumer is full (``EventDispatch/readerWait``), after the line and outside its
/// hang scope.
final class LineTransport: Sendable {
    /// `index` counts events on this transport from 1, in wire order.
    typealias EventHandler = @Sendable (_ name: String, _ line: Data, _ index: UInt64) -> Void
    typealias CloseHandler = @Sendable (TransportCloseReason) -> Void

    /// Inbound limit: the server may send up to 32 MiB (VT replay).
    static let maxLineBytes = 64 << 20
    /// SO_SNDBUF and SO_RCVBUF of the socket, and the reader's read size: the daemon's own value
    /// (p05-ipc-083), so a burst of output or a pipelined handshake moves in a few reads, not in hundreds
    /// of the 8 KiB AF_UNIX default.
    static let socketBufferBytes = 512 << 10
    /// The event name a `cmux.protocol/2` stream line is routed under
    /// (`DaemonEvent.decode`); the connection opens one stream, `session.events`.
    static let streamEvent = "cmux.protocol/2 stream"
    /// The reader's budget for one line (decode and route it): a jank past it, a hang dump 2 s later.
    /// A line is a few microseconds, so 100 ms means the reader thread is stuck.
    static let lineHangDeadline: Duration = .milliseconds(100)

    /// Guards the descriptor: writes and close are serialized so a write never
    /// lands on a reused fd.
    private struct Socket {
        var fd: Int32
    }

    /// The transport's routing state (LineTransport+State.swift); the reader's routing reads it
    /// (LineTransport+Route.swift).
    let state = Mutex(State(), rank: .daemonLineTransportState)
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
    /// counts nothing (a release build that did not opt in to field data).
    let recorder: DaemonWireStats.Recorder?
    /// Decodes this connection's lines on its reader thread, counting into ``recorder``; event
    /// handlers, which run there, decode with it too.
    let decoder: WireDecoder
    /// Watches the reader's handling of each line, never its wait in `read(2)`; nil watches nothing.
    let hangWatched: HangWatchedLane?
    /// The connection's decode sequence: event handlers, reply resolutions and the close run here, in wire order.
    let lane: DecodeLane
    /// The one timer of every reply deadline on this connection, armed for the earliest (``DeadlineHeap``).
    private let deadlineTimer: DemandTimer
    /// Time since the connection opened, on the clock ``deadlineTimer`` sleeps on.
    private let elapsed: @Sendable () -> Duration
    /// ``elapsed`` in nanoseconds when the reader last read bytes: the heartbeat's silence (``inboundSilence``).
    private let lastInbound = Atomic<Int64>(0)
    /// Where each request's `daemon.request` slice goes (LineTransport+RequestTrace.swift), the top bits of its
    /// async id (``traceConnectionBits(scope:)``) and its flow's seed (``requestFlowSeed(pid:)``).
    let trace: TraceRuntime, traceConnection: UInt64, traceFlowSeed: UInt64

    /// - Parameter opened: An opened bridge (``open(path:bridge:role:stats:hangs:writerTarget:trace:)``); nil connects to `path`.
    /// - Parameter stats: Where the connection counts (``DaemonEndpoint/wireStats``); nil for none.
    /// - Parameter hangs: Watches each line the reader handles and each writer drain step; nil: none. `writerTarget`: see `open`.
    /// - Parameter clock: What reply deadlines are measured and slept on; tests pass a `ManualClock`.
    init(path: String, opened: DaemonBridge.Opened? = nil, role: DaemonWireStats.Role, stats: DaemonWireStats?,
         hangs: (any HangWatchScoping)? = nil, writerTarget: DispatchQueue? = nil, trace: TraceRuntime = .shared,
         clock: any Clock<Duration> = ContinuousClock()) throws(DaemonError) {
        self.path = path
        self.role = role
        self.trace = trace
        traceConnection = Self.traceConnectionBits(scope: trace.nextAsyncScope())
        traceFlowSeed = Self.requestFlowSeed(pid: getpid())
        // timer-class-allow: off main: the request deadlines fail their expired requests from the transport's own state; no main-thread job
        deadlineTimer = DemandTimer(owner: "LineTransport.deadline", clock: clock)
        elapsed = Self.elapsedReader(clock)
        let recorder = stats?.recorder()
        self.recorder = recorder
        decoder = WireCoding.decoder(recorder)
        let fd: Int32
        if let opened {
            fd = opened.fd
            child = opened.child
        } else {
            fd = try Self.connect(path)
            child = nil
        }
        Self.sizeBuffers(fd)
        socket = Mutex(Socket(fd: fd), rank: .daemonLineTransportSocket)
        writer = SocketWriter(fd: fd, label: "com.cmuxterm.next.daemon.write", qos: role.writerQoS, target: writerTarget, hangs: hangs)
        recorder?.connectionOpened(role, bridged: opened != nil)
        // After the last throw: a transport that never opened registers nothing (its deinit does not run).
        hangWatched = hangs.map { HangWatchedLane("daemon.line", deadline: Self.lineHangDeadline, on: $0) }
        lane = DecodeLane(label: "com.cmuxterm.next.daemon.decode", qos: role.decodeQoS, lightQoS: role.writerQoS,
                          hangs: hangs)
    }

    /// The socket's SO_SNDBUF and SO_RCVBUF as the kernel reports them; nil once it closed.
    var socketBuffers: (send: Int, receive: Int)? {
        socket.withLock { socket -> (send: Int, receive: Int)? in socket.fd >= 0 ? Self.bufferSizes(socket.fd) : nil }
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
    ///
    /// - Parameter dispatch: how heavy each event is and the reader's wait for the handler's consumer; the
    ///   default decodes every event on the lane's queue. `onEvent` and `onClose` run on the lane, in wire order.
    ///   The reader's waits (the lane's backlog, then ``EventDispatch/readerWait``) run after each line it handled,
    ///   outside the line's hang scope: an event handler that found its consumer behind leaves the reader a wait
    ///   (``DaemonEventRoute/waitWhileReaderParked()``), which is idle time, not a hang.
    func start(dispatch: EventDispatch = .control, onCausedEvent onEvent: @escaping CausedEventHandler,
               onClose: @escaping CloseHandler) {
        let fd = socket.withLock { $0.fd }
        let thread = Thread { [self] in
            readLoop(fd: fd, dispatch: dispatch, onEvent: onEvent, onClose: onClose)
        }
        thread.name = "cmux-tui reader \(path)"
        thread.qualityOfService = role.readerQoS
        thread.start()
    }

    var isClosed: Bool { state.withLock { $0.closed != nil } }
    /// The connection runs through a bridge child (``DaemonBridge``), which carries bytes but no descriptors.
    var bridged: Bool { child != nil }
    /// The writer queue's class (``DaemonWireStats/Role/writerQoS``; tests).
    var writerQoS: DispatchQoS { writer.queueQoS }
    /// How long since the daemon last sent anything (a reply, an event, a stream line); from the open until its first.
    var inboundSilence: Duration { elapsed() - .nanoseconds(lastInbound.load(ordering: .relaxed)) }
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
    /// With `framed`, a typed v12 command goes as a REQUEST frame once the connection holds `ipc-frames-v2`
    /// (``FramedRequests``).
    func request(cmd: DaemonCommandName, timeout: Duration?, framed: Bool = false,
                 _ body: (UInt64) throws -> Data) async throws -> Response {
        let slot = ReplySlot()
        #if DEBUG || CMUX_BENCH_HOOKS
        // A traced new terminal: the request naming its id, and that request's reply.
        let armed = NewTerminalTrace.shared.isArmed
        var traced: String?
        #endif
        submit(.reply(cmd: cmd.wire, slot), deadline: timeout.map { self.deadline(after: $0) }, framed: framed) { id in
            let line = try body(id)
            #if DEBUG || CMUX_BENCH_HOOKS
            if armed { traced = NewTerminalTrace.shared.requestSent(line) }
            #endif
            beginRequestSpan(cmd, id: id, slot: slot)
            return line
        }
        // A failed submit resolved the slot already.
        let response = try await slot.value()
        #if DEBUG || CMUX_BENCH_HOOKS
        if let traced { NewTerminalTrace.shared.mark(.reply, terminal: traced) }
        #endif
        return response
    }

    /// The deadline `timeout` from now.
    func deadline(after timeout: Duration) -> DeadlineHeap.Deadline {
        DeadlineHeap.Deadline(at: elapsed() + timeout, timeout: timeout)
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

    /// Allocates the id, registers the waiter and its `deadline`, and writes, all under the
    /// socket lock so the pending requests' send order equals wire order. On failure before
    /// registration the waiter is resumed here; after it, `failAll` owns it. A `deadline` applies
    /// only to a waiter that awaits its reply.
    /// With `framed`, the request goes as a REQUEST frame when the connection frames its method
    /// (``FramedRequests``), else as a line.
    /// Returns the request id once the waiter is registered.
    @discardableResult
    func submit(_ waiter: Waiter, deadline: DeadlineHeap.Deadline? = nil, framed: Bool = false,
                _ body: (UInt64) throws -> Data) -> Result<UInt64, any Error> {
        var writeFailure: String?
        var submittedID: UInt64 = 0
        let early: (any Error)? = socket.withLock { socket -> (any Error)? in
            let id: UInt64
            let framing: FramedRequests?
            switch state.withLock({ state -> Result<(UInt64, FramedRequests?), DaemonError> in
                if let reason = state.closed { return .failure(Self.closedError(reason)) }
                defer { state.nextID += 1 }
                return .success((state.nextID, framed ? state.framing : nil))
            }) {
            case .success(let value): (id, framing) = value
            case .failure(let error): return error
            }
            let payload: Data
            do { payload = try body(id) } catch { return error }
            let stamp = recorder?.requestSent(waiter.cmd)
            let timed: (deadline: DeadlineHeap.Deadline, now: Duration)? =
                if let deadline, case .reply = waiter { (deadline: deadline, now: elapsed()) } else { nil }
            state.withLock { state in
                state.pending.append(PendingRequest(waiter: waiter, sent: stamp), id: id)
                if let timed {
                    state.deadlines.insert(id: id, timed.deadline)
                    armDeadlineTimer(&state, now: timed.now)
                }
            }
            submittedID = id
            let message = Self.message(payload, id: id, cmd: waiter.cmd, framing: framing)
            writeFailure = socket.fd >= 0 ? writer.write(message)?.description : "socket closed"
            if writeFailure == nil { recorder?.lineWritten(bytes: message.count) }
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

    /// Arms the one timer for the earliest deadline unless it is armed at or before it already. Called
    /// with the state lock held, so two submits never arm out of order; the timer's own lock is taken
    /// after it, and its fire runs with that lock released.
    private func armDeadlineTimer(_ state: inout State, now: Duration) {
        guard let at = state.nextArm() else { return }
        deadlineTimer.schedule(after: max(at - now, .zero)) { [weak self] in self?.fireDeadlines() }
    }

    /// Takes `id`'s deadline out, with the state lock held. When the timer was armed for it, the timer
    /// moves to the next deadline, or is cancelled when none is left, so an answered request causes no
    /// wakeup. Chrome does the same when a removed delayed task was the top of the queue's heap
    /// (`TaskQueueImpl::RemoveCancelableTask` calls `UpdateWakeUp`, base/task/sequence_manager/task_queue_impl.cc).
    /// The cancel stays under the state lock, as ``armDeadlineTimer(_:now:)`` does, so it never drops a
    /// timer a later submit armed.
    func removeDeadline(_ state: inout State, id: UInt64) {
        guard state.deadlines.remove(id: id) != nil, let armedAt = state.armedAt else { return }
        guard let next = state.deadlines.first?.deadline.at else {
            state.armedAt = nil
            deadlineTimer.cancel()
            return
        }
        guard next > armedAt else { return }
        state.armedAt = nil
        armDeadlineTimer(&state, now: elapsed())
    }

    /// Fails every pending request whose deadline passed with `timedOut`, then arms the timer for the
    /// next deadline.
    private func fireDeadlines() {
        let now = elapsed()
        let expired = state.withLock { state -> [Expired] in
            let expired = state.expireDue(at: now)
            armDeadlineTimer(&state, now: now)
            return expired
        }
        for request in expired {
            if let sent = request.sent { recorder?.timedOut(sent) }
            request.slot.resolve(.failure(DaemonError.timedOut("\(request.cmd) (no reply within \(request.timeout))")))
        }
    }

    private func failAll(_ reason: TransportCloseReason) {
        let unanswered: [PendingRequest] = state.withLock { state in
            if state.closed == nil { state.closed = reason }
            state.deadlines.removeAll()
            state.armedAt = nil
            return state.pending.removeAllInSendOrder()
        }
        deadlineTimer.cancel()
        let error = Self.closedError(reason)
        for entry in unanswered {
            // A request the connection closed under never gets its reply.
            if let sent = entry.sent { recorder?.abandoned(sent) }
            switch entry.waiter {
            case .reply, .handled: entry.waiter.failure?(error)
            case .discard, .expired: break
            }
        }
    }

    private func readLoop(fd: Int32, dispatch: EventDispatch, onEvent: @escaping CausedEventHandler,
                          onClose: @escaping CloseHandler) {
        DecodeLane.markReader()
        let decoder = self.decoder
        // An attach connection carries the terminal's output: the reader's copies of its bytes
        // are copies of that output (``DaemonWireStats/Snapshot/outputBytesCopiedApp``).
        let outputStream = role == .terminalAttach ? recorder : nil
        // Frames come only with their negotiation (p05-ipc-092); until the handshake asks for them
        // (``acceptFrames()``) a 0xFF boundary is a bad message.
        var reader = FrameReader(limits: FrameReader.Limits(maxLine: Self.maxLineBytes, maxFramePayload: FrameHeader.maxPayloadCap))
        var framesAccepted = false
        var chunk = [UInt8](repeating: 0, count: Self.socketBufferBytes)
        var closeDetail = "EOF"
        // wakeup-allow: bounded: blocking read on a dedicated thread; EOF, errors and bad messages end it, EINTR retries
        while true {
            // SAFETY: read writes at most $0.count bytes into the array's own storage, which the closure lends
            // for the call and nothing else touches meanwhile.
            let count = unsafe chunk.withUnsafeMutableBytes { unsafe blockingRead(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                closeDetail = "read: \(POSIXErrorText(errno))"
                break
            }
            recorder?.bytesRead(count)
            let (seconds, attoseconds) = elapsed().components
            lastInbound.store(seconds &* 1_000_000_000 &+ attoseconds / 1_000_000_000, ordering: .relaxed)
            outputStream?.outputCopied(count)  // into the reader's buffer
            // SAFETY: push copies the first `count` bytes of the array's own storage, the ones read(2) just
            // wrote (count <= its size); the closure lends the storage for the call only.
            unsafe chunk.withUnsafeBytes { unsafe reader.push(UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            if !framesAccepted, acceptsFrames {
                reader.negotiateFrames()
                framesAccepted = true
            }
            var next = Self.nextMessage(&reader)
            var unrouted: String?
            while case .success(let message?) = next, unrouted == nil {
                unrouted = self.dispatch(message, decoder: decoder, outputStream: outputStream, events: dispatch,
                                         onEvent: onEvent)
                if unrouted == nil { next = Self.nextMessage(&reader) }
            }
            if let unrouted {
                closeDetail = "bad message: \(unrouted)"
                break
            }
            if case .failure(let bad) = next {
                closeDetail = "bad message: \(bad.reason)"
                break
            }
        }
        let reason: TransportCloseReason = state.withLock { state in
            if let closed = state.closed { return closed }
            return state.sawShutdown ? .daemonShutdown : .lost(closeDetail)
        }
        failAll(reason)
        writer.close()
        closeDescriptor()
        // Every open attach stream ends, then the connection, each after every event and reply the reader
        // handed the lane.
        let streams = takeAttachStreams()
        lane.post(.heavy, bytes: 0) {
            for stream in streams { stream.deliver(.lost(reason)) }
            onClose(reason)
        }
    }

    /// Stream-0 events routed so far; a reply captures it as its barrier.
    /// After p05-ipc-120 it bounds every event the daemon emitted before that
    /// reply (cmux-tui/spec/transports.md "Reply and event order", rule 2).
    /// Until then the daemon's subscription hop can write the reply before
    /// the request's own events, so the barrier can miss them.
    var routedEventCount: UInt64 { state.withLock { $0.eventCount } }

    /// Routes one line inside a hang scope of ``lineHangDeadline`` (Chrome watches each IO-thread task
    /// the same way, base/threading/hang_watcher.cc). Returns the wait an attach stream's item leaves the reader.
    func handle<Line: RandomAccessCollection<UInt8>>(_ bytes: Line, decoder: WireDecoder, dispatch: EventDispatch,
                                                     onEvent: @escaping CausedEventHandler) -> AttachStreamRouted?
    where Line.Index == Int {
        guard let hangWatched else { return route(bytes, decoder: decoder, dispatch: dispatch, onEvent: onEvent) }
        return hangWatched.run { route(bytes, decoder: decoder, dispatch: dispatch, onEvent: onEvent) }
    }
}
