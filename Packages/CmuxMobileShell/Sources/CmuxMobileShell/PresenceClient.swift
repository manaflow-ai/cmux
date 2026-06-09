public import Foundation

/// Typed client for the cmux device presence service (`workers/presence`),
/// the realtime online/offline layer over the durable device registry. This is
/// the seam for the iOS device tree
/// (https://github.com/manaflow-ai/cmux/pull/5648): the tree renders the
/// registry's durable rows, and presence updates decide which rows get a live
/// "online" dot. Wiring these updates into the tree UI is a follow-up; this
/// file owns the wire types and the subscribe transport.
///
/// Wire protocol (mirrors `workers/presence/src/core.ts`): subscribing yields
/// one `snapshot` message, then `online` / `offline` / `seen` transition
/// events. Identities match the registry: `deviceId` is the cmux device UUID
/// (`devices.device_uuid`) and `tag` the app-instance tag
/// (`device_app_instances.tag`).
///
/// Auth mirrors ``DeviceRegistryService``: `Authorization: Bearer <access>`
/// plus optional `X-Cmux-Team-Id`, with tokens supplied through injected
/// Sendable closures so this client needs no dependency on the auth package.
public enum PresenceWire {
    /// One running cmux app instance on a device.
    public struct Instance: Codable, Equatable, Sendable {
        public var deviceId: String
        public var tag: String
        public var platform: String
        public var displayName: String?
        public var capabilities: [String]
        public var online: Bool
        /// Epoch milliseconds, matching the service's JSON.
        public var lastSeenAt: Double
        public var onlineSince: Double?
        public var offlineAt: Double?
    }

    /// Per-device rollup: online when any instance is online.
    public struct Device: Codable, Equatable, Sendable {
        public var deviceId: String
        public var platform: String
        public var displayName: String?
        public var online: Bool
        public var lastSeenAt: Double
        public var instances: [Instance]
    }

    /// The full presence map delivered first on every subscribe.
    public struct Snapshot: Codable, Equatable, Sendable {
        public var teamId: String
        public var now: Double
        /// Server-owned heartbeat cadence; clients render staleness from this
        /// rather than hardcoding the service's timing.
        public var heartbeatIntervalMs: Double
        public var offlineTimeoutMs: Double
        public var devices: [Device]
    }

    public enum OfflineReason: String, Codable, Sendable {
        case timeout
        case goodbye
    }

    /// One message from the subscribe stream.
    public enum Update: Equatable, Sendable {
        case snapshot(Snapshot)
        case online(Instance)
        case offline(Instance, reason: OfflineReason)
        /// Lightweight heartbeat tick on an already-online instance.
        case seen(deviceId: String, tag: String, lastSeenAt: Double)
    }

    public struct UnknownMessageError: Error, Sendable {
        public var type: String
    }

    /// Decode one subscribe-stream message. Pure and synchronous for tests.
    public static func parseUpdate(_ data: Data) throws -> Update {
        struct Typed: Decodable { var type: String }
        struct OnlinePayload: Decodable { var instance: Instance }
        struct OfflinePayload: Decodable {
            var instance: Instance
            var reason: OfflineReason
        }
        struct SeenPayload: Decodable {
            var deviceId: String
            var tag: String
            var lastSeenAt: Double
        }
        let decoder = JSONDecoder()
        let typed = try decoder.decode(Typed.self, from: data)
        switch typed.type {
        case "snapshot":
            return .snapshot(try decoder.decode(Snapshot.self, from: data))
        case "online":
            return .online(try decoder.decode(OnlinePayload.self, from: data).instance)
        case "offline":
            let payload = try decoder.decode(OfflinePayload.self, from: data)
            return .offline(payload.instance, reason: payload.reason)
        case "seen":
            let payload = try decoder.decode(SeenPayload.self, from: data)
            return .seen(deviceId: payload.deviceId, tag: payload.tag, lastSeenAt: payload.lastSeenAt)
        default:
            throw UnknownMessageError(type: typed.type)
        }
    }

    /// The WebSocket subscribe URL for a service base URL, or nil when the
    /// base URL is not http(s). Pure for tests.
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
}

/// Subscribes to the team's live presence stream over WebSocket.
///
/// Stub scope: connect, authenticate, decode. Reconnect/backoff policy and the
/// device-tree binding land with the iOS UI follow-up.
public actor PresenceClient {
    /// Supplies the Stack access token, or nil when there is no session.
    public struct TokenSource: Sendable {
        public var accessToken: @Sendable () async -> String?

        public init(accessToken: @escaping @Sendable () async -> String?) {
            self.accessToken = accessToken
        }
    }

    private let serviceBaseURL: String
    private let tokenSource: TokenSource
    private let teamIDProvider: @Sendable () async -> String?
    private let session: URLSession

    /// - Parameters:
    ///   - serviceBaseURL: Presence service origin (no trailing slash), e.g.
    ///     the deployed cmux-presence worker URL.
    ///   - tokenSource: Supplies the Stack access token.
    ///   - teamIDProvider: Team to scope to, or nil for the server default
    ///     (the caller's selected team).
    public init(
        serviceBaseURL: String,
        tokenSource: TokenSource,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil },
        session: sending URLSession = .shared
    ) {
        self.serviceBaseURL = serviceBaseURL
        self.tokenSource = tokenSource
        self.teamIDProvider = teamIDProvider
        self.session = session
    }

    public struct NotAuthenticatedError: Error, Sendable {}
    public struct InvalidServiceURLError: Error, Sendable {}

    /// Open the subscribe stream: one `.snapshot` first, then transitions.
    /// The stream finishes when the socket closes and throws on transport or
    /// decode errors; the consumer owns reconnect policy.
    public func subscribe() async throws -> AsyncThrowingStream<PresenceWire.Update, any Error> {
        guard let url = PresenceWire.subscribeURL(serviceBaseURL: serviceBaseURL) else {
            throw InvalidServiceURLError()
        }
        guard let accessToken = await tokenSource.accessToken() else {
            throw NotAuthenticatedError()
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let teamID = await teamIDProvider(), !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        let task = session.webSocketTask(with: request)
        task.resume()

        return AsyncThrowingStream { continuation in
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
                        continuation.yield(try PresenceWire.parseUpdate(data))
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
