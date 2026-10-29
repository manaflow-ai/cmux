import Foundation
import OSLog

@MainActor
protocol PresenceSocket: AnyObject {
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    var state: URLSessionTask.State { get }
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

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// Reconnects now (app foreground).
    public func kick() {
        guard socket == nil || socket?.state != .running else { return }
        stop()
        start()
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let request = try await signalRequest()
                let socket = makeSocket(request)
                self.socket = socket
                socket.resume()
                var sawHello = false
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data = switch message {
                    case .string(let text): Data(text.utf8)
                    case .data(let bytes): bytes
                    @unknown default: Data()
                    }
                    switch SignalFrame.parse(data) {
                    case .hello(_, let macs):
                        sawHello = true
                        failures = 0
                        onUpdate(.connected(true))
                        onUpdate(.snapshot(macs))
                    case .presence(let mac):
                        onUpdate(.mac(mac))
                    case .error(let code, let message):
                        log.error("signal error \(code, privacy: .public): \(message, privacy: .public)")
                    case .other, nil:
                        break
                    }
                }
                _ = sawHello
            } catch {
                if Task.isCancelled { return }
                log.error("presence socket: \(String(describing: error), privacy: .public)")
            }
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
            onUpdate(.connected(false))
            failures += 1
            // Keep the list fresh over HTTP while the socket is down.
            if let macs = try? await fetchMacs() { onUpdate(.snapshot(macs)) }
            let delay: Duration = failures < 4 ? .seconds(1 << failures) : Self.pollInterval
            do { try await clock.sleep(for: delay) } catch { return }
        }
    }
}
