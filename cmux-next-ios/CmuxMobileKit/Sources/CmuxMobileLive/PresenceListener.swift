import Foundation
import OSLog

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

    private let api: LiveAPI
    private let teamID: String
    private let deviceID: String
    private let clock: any Clock<Duration>
    private let onUpdate: @MainActor (Update) -> Void
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    /// Poll interval while the socket is down.
    static let pollInterval: Duration = .seconds(20)

    public init(api: LiveAPI, teamID: String, deviceID: String, clock: any Clock<Duration> = ContinuousClock(),
                onUpdate: @escaping @MainActor (Update) -> Void) {
        self.api = api
        self.teamID = teamID
        self.deviceID = deviceID
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
                let request = try await api.signalRequest(teamID: teamID, deviceID: deviceID)
                let socket = URLSession.shared.webSocketTask(with: request)
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
            if let macs = try? await api.macs(teamID: teamID) { onUpdate(.snapshot(macs)) }
            let delay: Duration = failures < 4 ? .seconds(1 << failures) : Self.pollInterval
            do { try await clock.sleep(for: delay) } catch { return }
        }
    }
}
