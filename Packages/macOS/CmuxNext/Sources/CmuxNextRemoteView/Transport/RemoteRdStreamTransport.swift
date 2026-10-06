import Foundation
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
public nonisolated final class RemoteRdStreamTransport: RemoteViewStreamSource {
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
        var status = RemoteViewStatus(state: .connecting)
    }

    /// Queue-confined session state: the Rust core, the input channel, the
    /// handshake and the connection.
    private nonisolated final class Engine {
        let core: RemoteRdCore
        let input: RemoteRdInput
        var handshake: RemoteRdHandshake
        var connection: NWConnection?

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
            engine.handshake.viewerStopped()
            sendControl(.stop)
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
                engine.handshake.receive(control)
            case let .datagram(datagram):
                // InputAck datagrams; any other datagram is refused without a state change.
                try? engine.input.acknowledge(datagram: datagram)
            }
        }
        publishStatus()
        if engine.handshake.isEnded {
            finish()
            return
        }
        var out: [Data] = (try? engine.core.feedback(nowMicros: now)) ?? []
        out += (try? engine.input.packets(nowMicros: now)) ?? []
        for bytes in out {
            sendRaw(bytes)
        }
        armTimer(now: now)
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
        let status = RemoteViewStatus(path: .direct, state: engine.handshake.sessionState)
        state.withLock { state in
            guard state.status != status else { return }
            state.status = status
            state.statuses?.yield(status)
        }
    }

    private func finish() {
        timer.cancel()
        engine.connection?.cancel()
        engine.connection = nil
        state.withLock { state in
            state.units?.finish()
            state.cursors?.finish()
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
