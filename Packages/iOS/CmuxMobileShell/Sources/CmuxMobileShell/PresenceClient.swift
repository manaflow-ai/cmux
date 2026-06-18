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
        session: sending URLSession = .shared
    ) {
        self.serviceBaseURL = serviceBaseURL
        self.tokenSource = tokenSource
        self.teamIDProvider = teamIDProvider
        self.session = session
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
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                receiveLoop.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
