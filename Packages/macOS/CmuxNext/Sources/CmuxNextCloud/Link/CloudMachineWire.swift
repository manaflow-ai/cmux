public import Foundation
import CmuxNextWakeups

/// The Cloud machine event socket. `/v1/wire/cloud` carries ephemeral VM events;
/// the access token is used only to mint a one-use ticket and never goes into the
/// WebSocket subprotocol. Reconnects are event driven and back off after failure.
@MainActor
public final class CloudMachineWire {
    private let apiBaseURL: URL
    private let token: @Sendable () async throws -> String
    private let team: @Sendable () async -> String?
    private var runner: Task<Void, Never>?
    private var generation = 0

    public init(apiBaseURL: URL, token: @escaping @Sendable () async throws -> String,
                team: @escaping @Sendable () async -> String?) {
        self.apiBaseURL = apiBaseURL
        self.token = token
        self.team = team
    }

    public func start(_ sink: @escaping @MainActor (CloudPortChange) -> Void) {
        stop()
        let generation = generation
        runner = Task { [weak self] in await self?.run(generation, sink: sink) }
    }

    public func stop() {
        generation += 1
        runner?.cancel()
        runner = nil
    }

    private func run(_ generation: Int, sink: @escaping @MainActor (CloudPortChange) -> Void) async {
        var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
        while !Task.isCancelled, generation == self.generation {
            do {
                try await session(generation, sink: sink, onSubscribed: { backoff.reset() })
            } catch is CancellationError {
                return
            } catch {}
            do { try await backoff.wait(owner: "cloud.machine.wire.reconnect") } catch { return }
        }
    }

    private func session(_ generation: Int, sink: @escaping @MainActor (CloudPortChange) -> Void,
                         onSubscribed: () -> Void) async throws {
        let selectedTeam = await team()
        let access = try await token()
        let ticket = try await mintTicket(access: access)
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/v1/wire/cloud"
        guard let url = components.url else { throw CloudAPIError.transport("invalid Cloud wire URL") }
        var request = URLRequest(url: url)
        let teamProtocol = selectedTeam.flatMap { $0.isEmpty ? nil : "team.\($0)" }
        request.setValue(([
            "cmux.wire.v1", "ticket.\(ticket)", teamProtocol,
        ].compactMap { $0 }).joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            request.setValue(version, forHTTPHeaderField: "x-cmux-client-version")
        }
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 8 << 20
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        try await withTaskCancellationHandler {
            while !Task.isCancelled {
                let message = try await task.receive()
                let data: Data
                switch message {
                case let .string(text): data = Data(text.utf8)
                case let .data(bytes): data = bytes
                @unknown default: continue
                }
                guard generation == self.generation else { throw CancellationError() }
                guard let type = Self.frameType(data) else { continue }
                switch type {
                case "welcome":
                    try await task.send(.string(#"{"t":"subscribe"}"#))
                case "snapshot":
                    onSubscribed()
                case "ephemeral":
                    if let change = CloudPortChange.parseWireFrame(data) { sink(change) }
                default:
                    break
                }
            }
            throw CancellationError()
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private func mintTicket(access: String) async throws -> String {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("v1/wire/ticket"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"scope":"cloud"}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudAPIError.transport("Cloud wire ticket refused")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ticket = object["ticket"] as? String, !ticket.isEmpty else {
            throw CloudAPIError.decoding("Cloud wire ticket response")
        }
        return ticket
    }

    private nonisolated static func frameType(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["t"] as? String
    }
}
