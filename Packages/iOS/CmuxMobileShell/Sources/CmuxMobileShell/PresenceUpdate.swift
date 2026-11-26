public import Foundation

/// One message from the presence subscribe stream. The wire protocol mirrors
/// `workers/presence/src/core.ts`: a `snapshot` arrives first, then `online`,
/// `offline`, `seen`, and `routes` transition events.
public enum PresenceUpdate: Equatable, Sendable {
    /// The full presence map, delivered first on every subscribe.
    case snapshot(PresenceSnapshot)
    /// An instance transitioned to online.
    case online(PresenceInstance)
    /// An instance transitioned to offline, with the service's reason.
    case offline(PresenceInstance, reason: PresenceOfflineReason)
    /// Lightweight heartbeat tick on an already-online instance.
    case seen(deviceId: String, tag: String, lastSeenAt: Double)
    /// An online instance's attach routes changed (new port/IP). Carries the
    /// full updated instance so the phone can reconnect on the fresh routes
    /// without a registry round trip.
    case routes(PresenceInstance)

    /// Decode one subscribe-stream frame. Pure and synchronous for tests.
    /// Throws ``PresenceClientError/unknownMessage(type:)`` for message types
    /// this client does not understand.
    public static func parse(_ data: Data) throws -> PresenceUpdate {
        try JSONDecoder().decode(PresenceUpdate.self, from: data)
    }
}

extension PresenceUpdate: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case instance
        case reason
        case deviceId
        case tag
        case lastSeenAt
    }

    /// Decodes the tagged wire frame: the `type` field selects the case, and
    /// snapshot payload fields live on the same top-level object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "snapshot":
            self = .snapshot(try PresenceSnapshot(from: decoder))
        case "online":
            self = .online(try container.decode(PresenceInstance.self, forKey: .instance))
        case "offline":
            self = .offline(
                try container.decode(PresenceInstance.self, forKey: .instance),
                reason: try container.decode(PresenceOfflineReason.self, forKey: .reason)
            )
        case "seen":
            self = .seen(
                deviceId: try container.decode(String.self, forKey: .deviceId),
                tag: try container.decode(String.self, forKey: .tag),
                lastSeenAt: try container.decode(Double.self, forKey: .lastSeenAt)
            )
        case "routes":
            self = .routes(try container.decode(PresenceInstance.self, forKey: .instance))
        default:
            throw PresenceClientError.unknownMessage(type: type)
        }
    }
}
