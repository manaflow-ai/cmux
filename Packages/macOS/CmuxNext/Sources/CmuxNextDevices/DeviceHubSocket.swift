public import CmuxNextWakeups
public import Foundation

/// One open text WebSocket.
public protocol DeviceHubSocketConnection: Sendable {
    /// The next text frame; throws when the socket closes.
    func receive() async throws -> String
    func send(_ text: String) async throws
    func close()
}

/// Opens the User DO socket (a fresh, newly signed upgrade request each time).
public protocol DeviceHubSocketConnector: Sendable {
    func connect() async throws -> any DeviceHubSocketConnection
}

/// The User DO socket over URLSession, its upgrade request from the client.
public struct URLSessionDeviceHubConnector: DeviceHubSocketConnector {
    public let client: DeviceHubClient
    let session: URLSession

    public init(client: DeviceHubClient, session: URLSession = DeviceHubClient.transport) {
        self.client = client
        self.session = session
    }

    public func connect() async throws -> any DeviceHubSocketConnection {
        let handshake = try await client.userSocketHandshake()
        let task = session.webSocketTask(with: handshake.request)
        task.maximumMessageSize = 1 << 20
        task.resume()
        return URLSessionSocketConnection(task: task)
    }
}

/// A URLSessionWebSocketTask as a ``DeviceHubSocketConnection``.
public struct URLSessionSocketConnection: DeviceHubSocketConnection {
    let task: URLSessionWebSocketTask

    public init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func receive() async throws -> String {
        let message: URLSessionWebSocketTask.Message
        do { message = try await task.receive() } catch {
            // The server's close code, when it closed the socket (4000 replaced, 4001 removed).
            if task.closeCode != .invalid { throw DeviceHubSocket.Closed(code: task.closeCode.rawValue) }
            throw error
        }
        switch message {
        case let .string(text): return text
        case let .data(data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    public func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// The device's socket to its User DO: pushes in, `{type:'ping'}` out after an
/// interval of silence, and a reconnect with jittered backoff whenever it drops.
/// While a socket is open nothing else wakes it but frames and the ping: a socket with
/// traffic sends no ping at all, and an idle one pings once per ``pingInterval``, at most
/// ``pingLeeway`` late.
///
/// With the app's Energy Saver policy (``KeepaliveGate``) the ping holds only while the
/// Mac sleeps (``KeepaliveGate/Hold/systemSleep``): a Mac whose displays sleep is still the Mac Screen
/// host a phone reaches, and without the ping a dropped stream goes unseen. A wake that finds the
/// network closes the socket once and opens a new one within ``EnergyPolicy/reconnectJitter`` (a
/// backoff wait in progress ends early): the socket that slept is a dead TCP stream the OS has not
/// reported yet.
public final class DeviceHubSocket: Sendable {
    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        /// The last attempt failed; the next one follows the backoff.
        case reconnecting(String)
        /// Another connection of this device took over (close code 4000): no reconnect.
        case replaced
        /// The hub removed this device (close code 4001): no reconnect.
        case removed
    }

    /// The server closed the socket with `code`.
    public struct Closed: Error, Equatable, Sendable {
        public var code: Int
        public init(code: Int) { self.code = code }
    }

    public enum Event: Sendable, Equatable {
        case state(State)
        case push(DeviceHubPush)
    }

    let connector: any DeviceHubSocketConnector
    let pingInterval: Duration
    /// How late the ping may go after ``pingInterval`` of silence: a tenth of it (3 s of 30 s), so the
    /// OS can fold its wake into another one (Apple's Energy Efficiency Guide asks a timer tolerance of
    /// at least 10% of its interval). A keepalive need not be on time to the second.
    var pingLeeway: Duration { pingInterval / 10 }
    let backoff: Backoff
    let clock: any Clock<Duration>
    /// The app's Energy Saver policy (`MainWorkScheduler.energy`); nil pings and reconnects as if always awake.
    let energy: EnergyPolicySource?
    /// A value in 0..<1 that spreads the reconnect after a wake (tests pass a constant).
    let wakeJitter: @Sendable () -> Double

    public init(connector: any DeviceHubSocketConnector, pingInterval: Duration = .seconds(30),
                backoff: Backoff = Backoff(initial: .seconds(1), maximum: .seconds(60)), clock: any Clock<Duration> = ContinuousClock(),
                energy: EnergyPolicySource? = nil, wakeJitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.connector = connector
        self.pingInterval = pingInterval
        self.backoff = backoff
        self.clock = clock
        self.energy = energy
        self.wakeJitter = wakeJitter
    }

    /// Connects and keeps connecting until the calling task is cancelled.
    /// `handler` gets every state change and push, in order.
    public func run(_ handler: @escaping @Sendable (Event) async -> Void) async {
        var backoff = self.backoff
        let gate = KeepaliveGate(energy, hold: .systemSleep, random: wakeJitter)
        // timer-class-allow: run is nonisolated and its caller runs it off main (DeviceHub's socket task); off-main deadlines are DemandTimer's own use
        let keepalive = DemandTimer(owner: "DeviceHubSocket.ping", clock: clock)
        // timer-class-allow: the reconnect backoff of the same off-main loop
        let retry = DemandTimer(owner: "device-hub.socket", clock: clock)
        gate.follow { edge in if edge == .pause { keepalive.cancel() } }
        defer {
            gate.stop()
            keepalive.cancel()
            retry.cancel()
        }
        // wakeup-allow: backoff the reconnect loop; each pass waits on a connect, the socket's frames, or Backoff after a failure.
        while !Task.isCancelled {
            await handler(.state(.connecting))
            var failure = "the socket closed"
            var closeCode: Int?
            do {
                let connection = try await connector.connect()
                gate.opened(close: { connection.close() }, resume: { [self] in armPing(keepalive, connection, gate: gate) })
                await handler(.state(.connected))
                backoff.reset()
                do { try await serve(connection, handler, gate: gate, keepalive: keepalive) } catch {
                    failure = "\(error)"
                    closeCode = (error as? Closed)?.code
                }
                gate.closed()
                keepalive.cancel()
                connection.close()
            } catch {
                failure = "\(error)"
            }
            if Task.isCancelled { break }
            if closeCode == 4000 || closeCode == 4001 {
                await handler(.state(closeCode == 4000 ? .replaced : .removed))
                return
            }
            await handler(.state(.reconnecting(failure)))
            // concurrency-allow: the gate's retry wait is a one-shot DemandTimer on the injected clock (Backoff's step, or the short wait after a wake), not a blocking wait.
            do { try await gate.retryWait(&backoff, timer: retry) } catch { break }
        }
        await handler(.state(.disconnected))
    }

    /// Reads frames until the socket fails or the task is cancelled, with the keepalive armed while
    /// `gate` does not hold it.
    private func serve(_ connection: any DeviceHubSocketConnection, _ handler: @escaping @Sendable (Event) async -> Void,
                       gate: KeepaliveGate, keepalive: DemandTimer) async throws {
        try await withTaskCancellationHandler {
            armPing(keepalive, connection, gate: gate)
            // wakeup-allow: bounded by the socket: each pass waits for the next frame, and a closed socket throws.
            while !Task.isCancelled {
                let text = try await connection.receive()
                armPing(keepalive, connection, gate: gate)
                if let push = DeviceHubPush(text: text) { await handler(.push(push)) }
            }
        } onCancel: {
            // receive() does not end on cancellation by itself; closing the socket ends it.
            connection.close()
        }
    }

    /// PROTOCOL.md's keepalive, sent only after ``pingInterval`` of silence both ways: any frame from
    /// the server (the pong too) re-arms it, and the ping is the only frame this socket sends, so its
    /// send re-arms it too. Chromium sends its HTTP/2 connection-check PING only after a read silence
    /// the same way (net/spdy/spdy_session.cc, `SendPrefacePingIfNoneInFlight`). The deadline is never
    /// early and at most ``pingLeeway`` late. A failed send closes the socket, which ends the read.
    /// Nothing is armed while `gate` holds the keepalive.
    private func armPing(_ keepalive: DemandTimer, _ connection: any DeviceHubSocketConnection, gate: KeepaliveGate) {
        gate.whileAwake {
            // wakeup-allow: periodic DeviceHubSocket.ping only on a silent socket; the server answers without waking its object
            keepalive.schedule(after: pingInterval, tolerance: pingLeeway) { [weak keepalive, self] in
                do { try await connection.send(#"{"type":"ping"}"#) } catch {
                    connection.close()
                    return
                }
                if let keepalive { armPing(keepalive, connection, gate: gate) }
            }
        }
    }
}
