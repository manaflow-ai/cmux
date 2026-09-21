import CMUXMobileCore
public import Foundation

/// Subscribes to the team's live presence stream over WebSocket.
///
/// This is the typed client for the cmux device presence service
/// (`workers/presence`), the realtime online/offline layer over the durable
/// device registry, and the seam for the iOS device tree
/// (https://github.com/manaflow-ai/cmux/pull/5648): the tree renders the
/// registry's durable rows, and ``PresenceUpdate`` events decide which rows
/// get a live "online" dot. Wiring the updates into the tree UI is a
/// follow-up.
///
/// Auth mirrors ``DeviceRegistryService``: `Authorization: Bearer <access>`
/// plus optional `X-Cmux-Team-Id`, with tokens supplied through
/// ``PresenceTokenSource``.
///
/// Stub scope: connect, authenticate, decode. Reconnect/backoff policy and
/// the device-tree binding land with the iOS UI follow-up.
public actor PresenceClient {
    private let serviceBaseURL: String
    private let tokenSource: PresenceTokenSource
    private let teamIDProvider: @Sendable () async -> String?
    private let session: URLSession
    private let deviceIDProvider: @Sendable () -> String
    private let instanceTagProvider: @Sendable () -> String
    private var workspaceScope: String?
    private var heartbeatTask: Task<Void, Never>?

    /// Creates a presence client.
    ///
    /// - Parameters:
    ///   - serviceBaseURL: Presence service origin (no trailing slash), e.g.
    ///     the deployed cmux-presence worker URL.
    ///   - tokenSource: Supplies the Stack access token.
    ///   - teamIDProvider: Team to scope to, or nil for the server default
    ///     (the caller's selected team).
    ///   - session: URL session used for the WebSocket transport.
    public init(
        serviceBaseURL: String,
        tokenSource: PresenceTokenSource,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil },
        session: sending URLSession = .shared,
        deviceIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        instanceTagProvider: @escaping @Sendable () -> String = { "default" }
    ) {
        self.serviceBaseURL = serviceBaseURL
        self.tokenSource = tokenSource
        self.teamIDProvider = teamIDProvider
        self.session = session
        self.deviceIDProvider = deviceIDProvider
        self.instanceTagProvider = instanceTagProvider
    }

    /// Publishes the phone's active workspace and keeps it fresh while that
    /// scope remains visible. Passing nil immediately leaves the old scope.
    public func setWorkspaceScope(_ scope: String?) async {
        let trimmed = scope?.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaceScope = trimmed?.isEmpty == false ? trimmed : nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await sendWorkspaceHeartbeat()
        guard workspaceScope != nil else { return }
        heartbeatTask = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard (try? await clock.sleep(for: .seconds(15))) != nil else { return }
                guard let self else { return }
                await self.sendWorkspaceHeartbeat()
            }
        }
    }

    private func sendWorkspaceHeartbeat() async {
        guard let accessToken = await tokenSource.accessToken(),
              let teamID = await teamIDProvider() else { return }
        guard let url = Self.heartbeatURL(serviceBaseURL: serviceBaseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "deviceId": deviceIDProvider(),
            "platform": "ios",
            "tag": instanceTagProvider(),
            "workspaceId": workspaceScope ?? NSNull(),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: request)
    }

    /// The WebSocket subscribe URL for a service base URL, or nil when the
    /// base URL is not http(s) or ws(s). Pure for tests.
    public static func subscribeURL(serviceBaseURL: String) -> URL? {
        guard var comps = URLComponents(string: serviceBaseURL) else { return nil }
        switch comps.scheme?.lowercased() {
        case "https": comps.scheme = "wss"
        case "http": comps.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        let basePath = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = basePath + "/v1/presence/subscribe"
        return comps.url
    }

    private static func heartbeatURL(serviceBaseURL: String) -> URL? {
        guard var comps = URLComponents(string: serviceBaseURL) else { return nil }
        let path = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = path + "/v1/presence/heartbeat"
        return comps.url
    }

    /// Open the subscribe stream: one ``PresenceUpdate/snapshot(_:)`` first,
    /// then transitions. The stream finishes when the socket closes and
    /// throws on transport or decode errors; the consumer owns reconnect
    /// policy.
    public func subscribe() async throws -> AsyncThrowingStream<PresenceUpdate, any Error> {
        guard let url = Self.subscribeURL(serviceBaseURL: serviceBaseURL) else {
            throw PresenceClientError.invalidServiceURL
        }
        guard let accessToken = await tokenSource.accessToken() else {
            throw PresenceClientError.notAuthenticated
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let teamID = await teamIDProvider(), !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        let task = session.webSocketTask(with: request)
        task.resume()

        // Bounded buffer: the receive loop yields every frame (including the
        // team's 15s `seen` ticks), so the default unbounded policy would grow
        // without limit if the consumer stalls. Dropping oldest frames at
        // worst leaves the rendered map stale until the next snapshot, which
        // the protocol already guarantees soon: streams are deadline-bounded
        // server-side and every resubscribe starts snapshot-first.
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let receiveLoop = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case .string(let text):
                            data = Data(text.utf8)
                        case .data(let raw):
                            data = raw
                        @unknown default:
                            continue
                        }
                        switch continuation.yield(try PresenceUpdate.parse(data)) {
                        case .enqueued:
                            break
                        case .dropped:
                            // The buffer overflowed and a frame was lost. The
                            // protocol is stateful (snapshot + deltas), so
                            // continuing past a missed transition would render
                            // wrong live state until the next snapshot. End the
                            // stream instead; the consumer's reconnect gets a
                            // fresh snapshot first.
                            continuation.finish(throwing: PresenceClientError.updatesDropped)
                            return
                        case .terminated:
                            return
                        @unknown default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    if let response = task.response as? HTTPURLResponse,
                       response.statusCode == 429 {
                        let seconds = CmxRetryAfterPolicy().seconds(
                            from: response,
                            defaultSeconds: CmxRetryAfterPolicy().defaultRateLimitSeconds
                        ) ?? CmxRetryAfterPolicy().defaultRateLimitSeconds
                        continuation.finish(
                            throwing: PresenceClientError.rateLimited(
                                retryAfterSeconds: seconds
                            )
                        )
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                receiveLoop.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
