public import Foundation
import CmuxNextWakeups
import Network
import Synchronization

/// The in-app `cmux.rd/1` transport over the stream carrier: one TCP
/// connection carries control JSON and datagrams as `u8 type, u32 len`
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
    private let endpoint: RemoteRdLoopbackEndpoint
    // internal for the +Service extension file
    let hello: RemoteRdHello
    private let startKey: String
    private let control: Bool
    private let nowMicros: @Sendable () -> UInt64
    // internal for the +Service extension file
    let queue = DispatchQueue(label: "cmux.remote-view.rd-transport")
    private let timer = DemandTimer(owner: "RemoteRdStreamTransport.deadline")
    // internal for the +Service extension file
    let state: Mutex<Continuations>
    // internal for the +Service extension file
    // crash-allow: confined to the serial `queue`; every access runs in a queue block or an NWConnection callback started on it.
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

    /// Queue-confined session state: the Rust core, the input channel, the
    /// handshake and the connection.
    // internal for the +Service extension file
    nonisolated final class Engine {
        let core: RemoteRdSession
        let input: RemoteRdInput
        var handshake: RemoteRdHandshake
        var connection: NWConnection?
        /// Cuts received bytes after control frames (surface streams open in between).
        var splitter = RemoteRdStreamSplitter()
        /// Created from the welcome's caps; ends with the session.
        var upstream: RemoteUpstreamConsent?

        init(core: RemoteRdSession, input: RemoteRdInput, service: String) {
            self.core = core
            self.input = input
            handshake = RemoteRdHandshake(service: service)
        }
    }

    /// `startKey` and `control` form the start message (`mode` view or
    /// control); `nowMicros` is a monotonic clock (injected for tests). Nil
    /// only when the Rust core cannot allocate its state.
    public init?(
        endpoint: RemoteRdLoopbackEndpoint, hello: RemoteRdHello, startKey: String, control: Bool = false,
        nowMicros: @escaping @Sendable () -> UInt64 = RemoteRdStreamTransport.monotonicMicros
    ) {
        guard let core = RemoteRdSession(carrier: .stream), let input = RemoteRdInput(carrier: .stream) else { return nil }
        var streamHello = hello
        streamHello.udpPort = nil
        self.endpoint = endpoint
        self.hello = streamHello
        self.startKey = startKey
        self.control = control
        self.nowMicros = nowMicros
        engine = Engine(core: core, input: input, service: hello.service)
        state = Mutex(Continuations())
    }

    deinit {
        timer.cancel()
        engine.connection?.cancel()
    }

    /// Monotonic microseconds (the core's clock).
    public static let monotonicMicros: @Sendable () -> UInt64 = {
        DispatchTime.now().uptimeNanoseconds / 1_000
    }

    /// Opens the connection and sends hello and start.
    public func connect() {
        queue.async { [self] in
            guard engine.connection == nil, !engine.handshake.isEnded else { return }
            let port = NWEndpoint.Port(rawValue: endpoint.port) ?? .any
            let connection = NWConnection(host: NWEndpoint.Host.ipv4(.loopback), port: port, using: .tcp)
            engine.connection = connection
            connection.stateUpdateHandler = { [weak self] newState in
                self?.connectionStateChanged(newState)
            }
            connection.start(queue: queue)
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

    /// Queues one input event (long text is split on character boundaries).
    public func send(_ event: RemoteInputEvent) {
        queue.async { [self] in
            guard !engine.handshake.isEnded else { return }
            let events: [RemoteInputEvent] = if case let .text(text) = event { RemoteInputEvent.textEvents(text) } else { [event] }
            for event in events {
                _ = try? engine.input.send(event)
            }
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

    private func connectionStateChanged(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            sendControl(.hello(hello))
            sendControl(.start(key: startKey, mode: control ? "control" : "view"))
            receiveNext()
        case .failed, .cancelled:
            closed()
        default:
            break
        }
    }

    private func receiveNext() {
        guard let connection = engine.connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                ingest(data)
            }
            if isComplete || error != nil {
                closed()
            } else if !engine.handshake.isEnded {
                receiveNext()
            }
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
        out += (try? engine.input.packets(nowMicros: now)) ?? []
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
                try? engine.input.acknowledge(datagram: datagram)
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
        let deadlines = [engine.core.nextDeadlineMicros, engine.input.nextDeadlineMicros].compactMap { $0 }
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
        engine.connection?.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard error != nil, let self else { return }
            queue.async { self.closed() }
        })
    }

    private func closed() {
        engine.handshake.connectionClosed()
        publishStatus()
        finish()
    }

    private func publishStatus() {
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
        engine.connection?.cancel()
        engine.connection = nil
        state.withLock { state in
            state.units?.finish()
            state.cursors?.finish()
            state.services?.finish()
            state.surfaces.endAll()
            state.statuses?.finish()
        }
    }
}
