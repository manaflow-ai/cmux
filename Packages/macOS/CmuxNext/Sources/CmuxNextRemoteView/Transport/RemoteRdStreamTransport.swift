public import Foundation
import CmuxNextWakeups
import CmuxNextCompat

/// The in-app `cmux.rd/1` transport over the stream carrier: one ordered
/// byte path (`RemoteRdByteCarrier`: loopback TCP, or a daemon
/// `loopback-forward-v1` stream to another machine) carries control JSON and datagrams as `u8 type, u32 len`
/// frames (until the overlay datagram service carries media). The shared Rust
/// core does reassembly, FEC, per-stream feedback (`RemoteRdSession`: the
/// page on stream 0, rb/1 popup surfaces on their own streams) and input redundancy
/// (`RemoteRdInput`); this type only moves bytes, runs the handshake
/// (`RemoteRdHandshake`) and arms one deadline timer (`DemandTimer`, never a
/// poll). Everything that touches the core runs on one serial queue.
/// Upstream media (C4b): the queue also owns the session's
/// `RemoteUpstreamConsent`, the single place that enforces the consent
/// contract; the pane drives it through `RemoteUpstreamControl`.
public nonisolated final class RemoteRdStreamTransport: RemoteViewStreamSource, RemoteUpstreamControl {
    private let carrier: any RemoteRdByteCarrier
    // internal for the +Service extension file
    let hello: RemoteRdHello
    private let startKey: String
    private let control: Bool
    // internal for the +Service extension file
    let nowMicros: @Sendable () -> UInt64
    // internal for the +Service extension file
    let queue = DispatchQueue(label: "cmux.remote-view.rd-transport", qos: .userInitiated)
    private let timer = DemandTimer(owner: "RemoteRdStreamTransport.deadline")
    // internal for the +Service extension file
    let state: Mutex<Continuations>
    // internal for the +Service extension file
    // crash-allow: confined to the serial `queue`; every access runs in a queue block or a carrier event, which runs on it.
    nonisolated(unsafe) let engine: Engine

    // internal for the +Service extension file
    struct Continuations {
        var units: AsyncStream<RemoteAccessUnit>.Continuation?
        var statuses: AsyncStream<RemoteViewStatus>.Continuation?
        var cursors: AsyncStream<RemoteCursorState>.Continuation?
        var services: AsyncStream<RemoteRdJSON>.Continuation?
        /// rb/1 popup surface streams and their buffered units.
        var surfaces = RemoteRdSurfaceStreams()
        var status = RemoteViewStatus(state: .connecting)
    }

    /// The input channel and the caller's outbox, which a key's turn on the main thread reaches without
    /// waiting for the queue: an input event takes its sequence number here
    /// (``sendServiceInput(_:mustDeliver:)``), and every frame the caller sends (input packets, service
    /// controls) joins the outbox in call order, which ``pump()`` sends before anything newer. Core calls
    /// and copies only, no I/O.
    // internal for the +Service extension file
    let inputChannel: Mutex<InputChannel>
    struct InputChannel {
        let input: RemoteRdInput
        /// The session ended (set on the queue): the caller's frames are dropped.
        var ended = false
        /// The welcome lists `input.service` (set on the queue).
        var serviceInputCap = false
        /// Frames from the caller's thread in call order: service controls and each input event's
        /// first packets (``RemoteRdInput`` sends packets after every event).
        var outbox: [Data] = []
        var acceptsService: Bool { !ended && serviceInputCap }

        /// Queues `events` and puts their packets in the outbox; false after the end.
        mutating func post(_ events: [RemoteInputEvent], nowMicros: UInt64) -> Bool {
            guard !ended else { return false }
            for event in events {
                _ = try? input.send(event)
            }
            outbox += (try? input.packets(nowMicros: nowMicros)) ?? []
            return true
        }
    }

    /// Queue-confined session state: the Rust core, the handshake and whether
    /// the carrier started.
    // internal for the +Service extension file
    nonisolated final class Engine {
        let core: RemoteRdSession
        var handshake: RemoteRdHandshake
        var started = false
        /// Cuts received bytes after control frames (surface streams open in between).
        var splitter = RemoteRdStreamSplitter()
        /// Created from the welcome's caps; ends with the session.
        var upstream: RemoteUpstreamConsent?

        init(core: RemoteRdSession, service: String) {
            self.core = core
            handshake = RemoteRdHandshake(service: service)
        }
    }

    /// A transport to a host on this Mac's loopback.
    public convenience init?(
        endpoint: RemoteRdLoopbackEndpoint, hello: RemoteRdHello, startKey: String, control: Bool = false,
        nowMicros: @escaping @Sendable () -> UInt64 = RemoteRdStreamTransport.monotonicMicros
    ) {
        self.init(carrier: RemoteRdLoopbackCarrier(endpoint: endpoint), hello: hello, startKey: startKey, control: control, nowMicros: nowMicros)
    }

    /// `startKey` and `control` form the start message (`mode` view or
    /// control); `nowMicros` is a monotonic clock (injected for tests). Nil
    /// only when the Rust core cannot allocate its state.
    public init?(
        carrier: any RemoteRdByteCarrier, hello: RemoteRdHello, startKey: String, control: Bool = false,
        nowMicros: @escaping @Sendable () -> UInt64 = RemoteRdStreamTransport.monotonicMicros
    ) {
        guard let core = RemoteRdSession(carrier: .stream), let input = RemoteRdInput(carrier: .stream) else { return nil }
        var streamHello = hello
        streamHello.udpPort = nil
        self.carrier = carrier
        self.hello = streamHello
        self.startKey = startKey
        self.control = control
        self.nowMicros = nowMicros
        engine = Engine(core: core, service: hello.service)
        inputChannel = Mutex(InputChannel(input: input))
        state = Mutex(Continuations())
    }

    deinit {
        timer.cancel()
        carrier.cancel()
    }

    /// Monotonic microseconds (the core's clock).
    public static let monotonicMicros: @Sendable () -> UInt64 = {
        DispatchTime.now().uptimeNanoseconds / 1_000
    }

    /// Opens the carrier and sends hello and start.
    public func connect() {
        queue.async { [self] in
            guard !engine.started, !engine.handshake.isEnded else { return }
            engine.started = true
            carrier.start(queue: queue) { [weak self] event in
                self?.carrierEvent(event)
            }
        }
    }

    /// Asks the host to end the session; the host answers ended and closes.
    public func stop() {
        queue.async { [self] in
            guard !engine.handshake.isEnded else { return }
            // Revoke upstream media first: nothing goes out after the user's stop.
            for stream in engine.upstream?.endSession() ?? [] {
                sendControl(.streamClose(stream: stream))
            }
            engine.handshake.viewerStopped()
            sendControl(.stop)
            publishStatus()
        }
    }

    /// Queues one input event (long text is split on character boundaries), in call order with the
    /// service controls and service input events (``sendService(_:)``,
    /// ``sendServiceInput(_:mustDeliver:)``). Never waits for the queue.
    public func send(_ event: RemoteInputEvent) {
        let events: [RemoteInputEvent] = if case let .text(text) = event { RemoteInputEvent.textEvents(text) } else { [event] }
        let now = nowMicros()
        guard inputChannel.withLock({ $0.post(events, nowMicros: now) }) else { return }
        sendOutbox()
    }

    /// Has the queue send the outbox (``InputChannel/outbox``); nothing after the session's end.
    // internal for the +Service extension file
    func sendOutbox() {
        queue.async { [self] in
            guard !engine.handshake.isEnded else { return }
            pump()
        }
    }

    // MARK: RemoteUpstreamControl

    public func requestUpstream(_ kind: RemoteUpstreamKind, permissionGranted: Bool) {
        queue.async { [self] in
            guard case .streaming = engine.handshake.phase, let consent = engine.upstream else { return }
            // A refusal (no cap, permission denied, ended) opens nothing.
            guard let open = try? consent.request(kind, permissionGranted: permissionGranted) else { return }
            sendControl(.streamOpen(open))
            publishStatus()
        }
    }

    public func stopUpstream(_ kind: RemoteUpstreamKind) {
        queue.async { [self] in
            guard let stream = engine.upstream?.stop(kind) else { return }
            sendControl(.streamClose(stream: stream))
            publishStatus()
        }
    }

    public func stopAllUpstreams() {
        queue.async { [self] in
            guard let consent = engine.upstream else { return }
            for kind in RemoteUpstreamKind.allCases {
                if let stream = consent.stop(kind) { sendControl(.streamClose(stream: stream)) }
            }
            publishStatus()
        }
    }

    /// Sends one encoded frame of an active kind (a capture pipeline's
    /// output); dropped when the kind has no consent.
    public func sendUpstream(_ kind: RemoteUpstreamKind, frame: Data, captureMicros: UInt64, independent: Bool) {
        queue.async { [self] in
            guard let sender = engine.upstream?.sender(kind) else { return }
            _ = try? sender.send(frame: frame, captureMicros: captureMicros, independent: independent, nowMicros: nowMicros())
            pump()
        }
    }

    // MARK: RemoteViewStreamSource

    public func accessUnits() -> AsyncStream<RemoteAccessUnit> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteAccessUnit.self, bufferingPolicy: .bufferingNewest(8))
        let previous = state.withLock { state in
            defer { state.units = continuation }
            return state.units
        }
        previous?.finish()
        return stream
    }

    public func statusUpdates() -> AsyncStream<RemoteViewStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteViewStatus.self, bufferingPolicy: .bufferingNewest(4))
        let (previous, current) = state.withLock { state in
            defer { state.statuses = continuation }
            return (state.statuses, state.status)
        }
        previous?.finish()
        continuation.yield(current)
        return stream
    }

    public func cursorUpdates() -> AsyncStream<RemoteCursorState> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteCursorState.self, bufferingPolicy: .bufferingNewest(1))
        let previous = state.withLock { state in
            defer { state.cursors = continuation }
            return state.cursors
        }
        previous?.finish()
        return stream
    }

    public func requestKeyframe() {
        requestKeyframe(stream: 0)
    }

    // MARK: Queue-confined work

    private func carrierEvent(_ event: RemoteRdCarrierEvent) {
        switch event {
        case .ready:
            sendControl(.hello(hello))
            sendControl(.start(key: startKey, mode: control ? "control" : "view"))
        case let .data(data):
            guard !engine.handshake.isEnded else { return }
            ingest(data)
        case .closed:
            closed()
        }
    }

    private func ingest(_ data: Data) {
        for segment in engine.splitter.split(data) {
            do {
                try engine.core.push(streamBytes: segment.bytes, nowMicros: nowMicros())
            } catch {
                // The stream broke or the host flooded the queues: end the session.
                closed()
                return
            }
            // A surface's frames follow its show in the same read: open its
            // stream before they are pushed.
            if segment.endsControlFrame { drainMessages(now: nowMicros()) }
        }
        pump()
    }

    /// Hands out ready frames and messages, sends due feedback and input, and
    /// arms the one timer for the next deadline.
    // internal for the +Service extension file
    func pump() {
        let now = nowMicros()
        _ = try? engine.core.tick(nowMicros: now)
        while let popped = try? engine.core.popAccessUnit(codec: .h264) {
            state.withLock { state in
                if popped.stream == 0 {
                    state.units?.yield(popped.unit)
                } else {
                    state.surfaces.yield(popped.unit, stream: popped.stream)
                }
            }
        }
        drainMessages(now: now)
        publishStatus()
        if engine.handshake.isEnded {
            finish()
            return
        }
        var out: [Data] = (try? engine.core.feedback(nowMicros: now)) ?? []
        // The caller's frames first, in its call order; then input packets due now (repeats of unacknowledged events).
        out += inputChannel.withLock { channel in
            defer { channel.outbox = [] }
            return channel.outbox + ((try? channel.input.packets(nowMicros: now)) ?? [])
        }
        for sender in engine.upstream?.activeSenders ?? [] {
            out += (try? sender.datagrams()) ?? []
        }
        for bytes in out {
            sendRaw(bytes)
        }
        armTimer(now: now)
    }

    /// Hands out queued control messages and datagrams.
    private func drainMessages(now: UInt64) {
        while let message = try? engine.core.popMessage() {
            switch message {
            case let .control(json):
                guard let control = try? RemoteRdControl.parse(json) else { continue }
                if case let .service(service, body) = control, service == hello.service, !engine.handshake.isEnded {
                    applySurfaceStreams(body)
                    _ = state.withLock { $0.services?.yield(body) }
                }
                engine.handshake.receive(control)
                handleUpstream(control)
            case let .datagram(datagram):
                // Upstream feedback goes to its sender; InputAck datagrams to
                // the input channel; any other datagram is refused without a state change.
                let senders = engine.upstream?.activeSenders ?? []
                if senders.contains(where: { (try? $0.receive(datagram: datagram, nowMicros: now)) == true }) { continue }
                inputChannel.withLock { _ = try? $0.input.acknowledge(datagram: datagram) }
            case .bulk:
                // Transfers belong to the service (rb/1 uploads and downloads); the desktop has none.
                break
            }
        }
    }

    /// The welcome creates the session's consent; stream answers update it.
    private func handleUpstream(_ control: RemoteRdControl) {
        if engine.upstream == nil, let welcome = engine.handshake.welcome {
            engine.upstream = RemoteUpstreamConsent(welcomeCaps: welcome.caps ?? [])
        }
        guard let consent = engine.upstream else { return }
        switch control {
        case let .streamOpened(stream):
            let maxDatagram = UInt32(clamping: engine.handshake.welcome?.maxDatagram ?? 1152)
            let result = consent.opened(stream: stream) { kind, stream in
                RemoteRdUpstream(carrier: .stream, stream: stream, kind: kind, maxDatagram: maxDatagram, path: RemoteRdUpstream.directLANPath)
            }
            if case let .failed(stream) = result { sendControl(.streamClose(stream: stream)) }
        case let .streamRefused(stream, _):
            consent.refused(stream: stream)
        case let .streamClose(stream):
            consent.closedByHost(stream: stream)
        default:
            break
        }
    }

    private func armTimer(now: UInt64) {
        let inputDeadline = inputChannel.withLock { $0.input.nextDeadlineMicros }
        let deadlines = [engine.core.nextDeadlineMicros, inputDeadline].compactMap { $0 }
        guard let next = deadlines.min() else {
            timer.cancel()
            return
        }
        let delay = next > now ? next - now : 0
        timer.schedule(after: .microseconds(Int64(clamping: delay))) { [weak self] in
            guard let self else { return }
            queue.async { self.pump() }
        }
    }

    // internal for the +Service extension file
    func sendControl(_ control: RemoteRdControl) {
        guard let json = try? control.json(), let frame = try? RemoteRdCore.streamFrame(json, control: true) else { return }
        sendRaw(frame)
    }

    private func sendRaw(_ bytes: Data) {
        guard engine.started else { return }
        carrier.send(bytes)
    }

    private func closed() {
        engine.handshake.connectionClosed()
        publishStatus()
        finish()
    }

    /// Publishes the handshake outside the queue: the pane's status, and whether the caller's input and
    /// service frames are taken (``send(_:)``, ``sendServiceInput(_:mustDeliver:)``). Runs after every
    /// handshake change.
    private func publishStatus() {
        let ended = engine.handshake.isEnded
        let serviceInputCap = engine.handshake.welcome?.caps?.contains(Self.inputServiceCap) == true
        inputChannel.withLock { channel in
            channel.ended = ended
            channel.serviceInputCap = serviceInputCap
            if ended { channel.outbox = [] }
        }
        var upstream = RemoteUpstreamStatus()
        if let consent = engine.upstream, case .streaming = engine.handshake.phase {
            upstream = RemoteUpstreamStatus(offered: consent.isOffered, requested: consent.requested, active: consent.active)
        }
        let status = RemoteViewStatus(path: .direct, state: engine.handshake.sessionState, upstream: upstream)
        state.withLock { state in
            guard state.status != status else { return }
            state.status = status
            state.statuses?.yield(status)
        }
    }

    private func finish() {
        // Session end, host stop or disconnect: revoke and free every sender.
        engine.upstream?.endSession()
        timer.cancel()
        carrier.cancel()
        state.withLock { state in
            state.units?.finish()
            state.cursors?.finish()
            state.services?.finish()
            state.surfaces.endAll()
            state.statuses?.finish()
        }
    }
}
