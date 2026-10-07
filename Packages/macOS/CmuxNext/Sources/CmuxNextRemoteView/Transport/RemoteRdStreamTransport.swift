public import Foundation
import CmuxNextWakeups
import Network
import Synchronization

/// A development host on this Mac's loopback interface (remote-desktop.md
/// 11.0: phase-1 hosts listen only on loopback). The transport connects to a
/// literal 127.0.0.1, never a resolved name.
public nonisolated struct RemoteRdLoopbackEndpoint: Sendable, Hashable {
    public let port: UInt16

    /// Nil for a privileged port (the host refuses ports below 1024 too).
    public init?(port: UInt16) {
        guard port >= 1024 else { return nil }
        self.port = port
    }
}

/// The in-app `cmux.rd/1` transport over the stream carrier: one TCP
/// connection carries control JSON and datagrams as `u8 type, u32 len`
/// frames (until the overlay datagram service carries media). The shared Rust
/// core does reassembly, FEC, feedback (`RemoteRdCore`) and input redundancy
/// (`RemoteRdInput`); this type only moves bytes, runs the handshake
/// (`RemoteRdHandshake`) and arms one deadline timer (`DemandTimer`, never a
/// poll). Everything that touches the core runs on one serial queue.
/// Upstream media (C4b): the queue also owns the session's
/// `RemoteUpstreamConsent`, the single place that enforces the consent
/// contract; the pane drives it through `RemoteUpstreamControl`.
public nonisolated final class RemoteRdStreamTransport: RemoteViewStreamSource, RemoteUpstreamControl {
    private let endpoint: RemoteRdLoopbackEndpoint
    private let hello: RemoteRdHello
    private let startKey: String
    private let control: Bool
    private let nowMicros: @Sendable () -> UInt64
    private let queue = DispatchQueue(label: "cmux.remote-view.rd-transport")
    private let timer = DemandTimer(owner: "RemoteRdStreamTransport.deadline")
    private let state: Mutex<Continuations>
    // crash-allow: confined to the serial `queue`; every access runs in a queue block or an NWConnection callback started on it.
    private nonisolated(unsafe) let engine: Engine

    private struct Continuations {
        var units: AsyncStream<RemoteAccessUnit>.Continuation?
        var statuses: AsyncStream<RemoteViewStatus>.Continuation?
        var cursors: AsyncStream<RemoteCursorState>.Continuation?
        var services: AsyncStream<RemoteRdJSON>.Continuation?
        var status = RemoteViewStatus(state: .connecting)
    }

    /// Queue-confined session state: the Rust core, the input channel, the
    /// handshake and the connection.
    private nonisolated final class Engine {
        let core: RemoteRdCore
        let input: RemoteRdInput
        var handshake: RemoteRdHandshake
        var connection: NWConnection?
        /// Created from the welcome's caps; ends with the session.
        var upstream: RemoteUpstreamConsent?

        init(core: RemoteRdCore, input: RemoteRdInput, service: String) {
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
        guard let core = RemoteRdCore(carrier: .stream), let input = RemoteRdInput(carrier: .stream) else { return nil }
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

    // MARK: Service (rd changes B3.2 and C2)

    /// The bodies of the session service's control messages (`service`
    /// messages whose service is the hello's), in order and never dropped.
    /// Subscribe before `connect()`: bodies that arrive with no subscriber
    /// are not kept. A new call finishes the previous stream.
    public func serviceMessages() -> AsyncStream<RemoteRdJSON> {
        // concurrency-allow: rb/1 control bodies (page state, menus, dialogs), not frames; the session drains them at once into its reducer, and a dropped body would desync it
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteRdJSON.self, bufferingPolicy: .unbounded)
        let previous = state.withLock { state in
            defer { state.services = continuation }
            return state.services
        }
        previous?.finish()
        return stream
    }

    /// Sends one control message of the session's service (`body` is an
    /// rb/1 message such as `rb.navigate`). Dropped after the session ended.
    public func sendService(_ body: RemoteRdJSON) {
        queue.async { [self] in
            guard !engine.handshake.isEnded else { return }
            sendControl(.service(service: hello.service, body: body))
        }
    }

    /// Queues one service input event (opaque bytes, tag 0x80) and returns
    /// its rd input sequence number, which the service's answers name (rb's
    /// `rb.key_unhandled {input_seq}`). Nil before the welcome, after the
    /// end, when the host's welcome does not list `input.service`, or for
    /// bytes the core refuses. Waits for the transport queue, so call it
    /// from outside that queue (the main actor).
    public func sendServiceInput(_ bytes: Data, mustDeliver: Bool) -> UInt32? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { [self] in
            guard !engine.handshake.isEnded,
                  engine.handshake.welcome?.caps?.contains(Self.inputServiceCap) == true,
                  let seq = try? engine.input.sendService(bytes, mustDeliver: mustDeliver) else { return nil }
            pump()
            return seq
        }
    }

    /// The rd cap that allows service input events (rd change C2).
    public static let inputServiceCap = "input.service"
    /// The remote browser tab service (`cmux.rb/1`, remote-tab-protocol.md).
    public static let remoteBrowserService = "rb/1"

    /// A transport for one remote browser tab: hello for service `rb/1` with
    /// the `input.service` cap, in control mode. The rb session itself
    /// (`rb.open`, menus, pages) runs over `serviceMessages` and
    /// `sendService`; frames of the page arrive as access units.
    public static func remoteBrowser(
        endpoint: RemoteRdLoopbackEndpoint, user: String, install: String, token: String? = nil,
        nowMicros: @escaping @Sendable () -> UInt64 = RemoteRdStreamTransport.monotonicMicros
    ) -> RemoteRdStreamTransport? {
        let hello = RemoteRdHello(user: user, install: install, token: token, service: remoteBrowserService, caps: [inputServiceCap])
        return RemoteRdStreamTransport(endpoint: endpoint, hello: hello, startKey: "tab", control: true, nowMicros: nowMicros)
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
        queue.async { [self] in
            try? engine.core.requestKeyframe()
            pump()
        }
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
        do {
            try engine.core.push(streamBytes: data, nowMicros: nowMicros())
        } catch {
            // The stream broke or the host flooded the queues: end the session.
            closed()
            return
        }
        pump()
    }

    /// Hands out ready frames and messages, sends due feedback and input, and
    /// arms the one timer for the next deadline.
    private func pump() {
        let now = nowMicros()
        _ = try? engine.core.tick(nowMicros: now)
        while let unit = try? engine.core.popAccessUnit(codec: .h264) {
            _ = state.withLock { $0.units?.yield(unit) }
        }
        while let message = try? engine.core.popMessage() {
            switch message {
            case let .control(json):
                guard let control = try? RemoteRdControl.parse(json) else { continue }
                if case let .service(service, body) = control, service == hello.service, !engine.handshake.isEnded {
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

    private func sendControl(_ control: RemoteRdControl) {
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
            state.statuses?.finish()
        }
    }
}

/// Sends the pane's captured input on a `RemoteRdStreamTransport`.
@MainActor
public final class RemoteRdTransportInputSink: RemoteViewInputSink {
    private let transport: RemoteRdStreamTransport

    public init(transport: RemoteRdStreamTransport) {
        self.transport = transport
    }

    public func send(_ event: RemoteInputEvent) {
        transport.send(event)
    }
}
