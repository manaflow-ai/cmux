import Foundation
import OSLog

@MainActor
protocol PresenceSocket: AnyObject {
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: PresenceSocket {}

private let log = Logger(subsystem: "dev.cmux.mobile", category: "presence")

/// Holds the team's signaling WebSocket for Mac presence (`hello` then
/// `presence` frames) on the app's presence device id, and reconnects with
/// backoff on an injected clock. While the socket is down, `GET /macs`
/// polls keep the list fresh.
@MainActor
public final class PresenceListener {
    public enum Update: Sendable {
        case snapshot([LiveAPI.Mac])
        case mac(LiveAPI.Mac)
        case connected(Bool)
    }

    private let signalRequest: @MainActor () async throws -> URLRequest
    private let fetchMacs: @MainActor () async throws -> [LiveAPI.Mac]
    private let makeSocket: @MainActor (URLRequest) -> any PresenceSocket
    private let clock: any Clock<Duration>
    private let onUpdate: @MainActor (Update) -> Void
    private var task: Task<Void, Never>?
    private var socket: (any PresenceSocket)?
    private var refreshTask: Task<Void, Never>?
    private var pingTimer: Task<Void, Never>?
    private var helloTimer: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var failures = 0
    private var active = false
    /// Poll interval while the socket is down.
    static let pollInterval: Duration = .seconds(20)
    static let pingInterval: Duration = .seconds(15)
    static let pingTimeout: Duration = .seconds(5)
    static let helloTimeout: Duration = .seconds(10)

    public convenience init(api: LiveAPI, teamID: String, deviceID: String, clock: any Clock<Duration> = ContinuousClock(),
                onUpdate: @escaping @MainActor (Update) -> Void) {
        self.init(clock: clock,
                  signalRequest: { try await api.signalRequest(teamID: teamID, deviceID: deviceID) },
                  fetchMacs: { try await api.macs(teamID: teamID) },
                  makeSocket: { URLSession.shared.webSocketTask(with: $0) }, onUpdate: onUpdate)
    }

    init(clock: any Clock<Duration>,
         signalRequest: @escaping @MainActor () async throws -> URLRequest,
         fetchMacs: @escaping @MainActor () async throws -> [LiveAPI.Mac],
         makeSocket: @escaping @MainActor (URLRequest) -> any PresenceSocket,
         onUpdate: @escaping @MainActor (Update) -> Void) {
        self.signalRequest = signalRequest
        self.fetchMacs = fetchMacs
        self.makeSocket = makeSocket
        self.clock = clock
        self.onUpdate = onUpdate
    }

    isolated deinit {
        task?.cancel()
        refreshTask?.cancel()
        pingTimer?.cancel()
        helloTimer?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    public func start() {
        guard !active else { return }
        active = true
        failures = 0
        connect()
    }

    public func stop() {
        active = false
        cancelAttempt()
    }

    /// A running URLSession task does not prove the peer is alive. Foreground
    /// and network changes replace it immediately, including any retry backoff.
    public func kick() {
        stop()
        onUpdate(.connected(false))
        start()
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        active && self.generation == generation
    }

    /// Invalidate first: canceled requests, receives and ping callbacks may still
    /// finish later. They must neither publish nor cancel the replacement socket.
    private func cancelAttempt() {
        generation &+= 1
        task?.cancel()
        task = nil
        refreshTask?.cancel()
        refreshTask = nil
        pingTimer?.cancel()
        pingTimer = nil
        helloTimer?.cancel()
        helloTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func connect() {
        cancelAttempt()
        let generation = generation
        // Bounds opening the socket through its first presence snapshot, even
        // when the peer answers pings but never sends hello. Cleared by hello.
        helloTimer = timer(after: Self.helloTimeout, generation: generation) { listener in
            listener.failed(generation, reason: "hello timed out")
        }
        task = Task { [weak self, signalRequest] in
            do {
                let request = try await signalRequest()
                guard let self, self.isCurrent(generation) else { return }
                let socket = self.makeSocket(request)
                self.socket = socket
                socket.resume()
                self.ping(generation)
                self.receive(socket, generation: generation)
            } catch {
                self?.failed(generation, reason: String(describing: error))
            }
        }
    }

    private func receive(_ socket: any PresenceSocket, generation: UInt64) {
        task = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.isCurrent(generation) else { return }
                    let data: Data = switch message {
                    case .string(let text): Data(text.utf8)
                    case .data(let bytes): bytes
                    @unknown default: Data()
                    }
                    switch SignalFrame.parse(data) {
                    case .hello(_, let macs):
                        self.helloTimer?.cancel()
                        self.helloTimer = nil
                        self.failures = 0
                        self.onUpdate(.connected(true))
                        guard self.isCurrent(generation) else { return }
                        self.onUpdate(.snapshot(macs))
                    case .presence(let mac):
                        self.onUpdate(.mac(mac))
                    case .error(let code, let message):
                        log.error("signal error \(code, privacy: .public): \(message, privacy: .public)")
                    case .other, nil:
                        break
                    }
                }
            } catch {
                self?.failed(generation, reason: String(describing: error))
            }
        }
    }

    private func ping(_ generation: UInt64) {
        guard isCurrent(generation), let socket else { return }
        // Only one ping is outstanding. Its deadline is replaced by the next
        // interval on pong; both are canceled by stop, kick or failure.
        pingTimer = timer(after: Self.pingTimeout, generation: generation) { listener in
            listener.failed(generation, reason: "ping timed out")
        }
        socket.sendPing { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(generation) else { return }
                self.pingTimer?.cancel()
                if let error {
                    self.failed(generation, reason: String(describing: error))
                } else {
                    self.pingTimer = self.timer(after: Self.pingInterval, generation: generation) { listener in
                        listener.ping(generation)
                    }
                }
            }
        }
    }

    private func timer(after delay: Duration, generation: UInt64,
                       action: @escaping @MainActor (PresenceListener) -> Void) -> Task<Void, Never> {
        Task { [weak self, clock] in
            do { try await clock.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, self.isCurrent(generation) else { return }
            action(self)
        }
    }

    private func failed(_ generation: UInt64, reason: String) {
        guard isCurrent(generation) else { return }
        log.error("presence socket: \(reason, privacy: .public)")
        cancelAttempt()
        let recoveryGeneration = self.generation
        onUpdate(.connected(false))
        guard isCurrent(recoveryGeneration) else { return }
        failures += 1
        let delay: Duration = failures < 4 ? .seconds(1 << failures) : Self.pollInterval
        // Refresh and retry are independent: a slow HTTP response cannot hold
        // the socket in backoff. Both are canceled on stop/kick/next attempt.
        refreshTask = Task { [weak self, fetchMacs] in
            if let macs = try? await fetchMacs() {
                guard let self, self.isCurrent(recoveryGeneration) else { return }
                self.onUpdate(.snapshot(macs))
            }
        }
        task = timer(after: delay, generation: recoveryGeneration) { listener in
            listener.connect()
        }
    }
}
