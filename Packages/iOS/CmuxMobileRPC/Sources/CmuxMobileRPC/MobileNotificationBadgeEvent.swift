public import Foundation

/// Typed decoder for a `notification.badge` push-event payload.
///
/// Emitted by the Mac whenever its unread-notification count changes (from the
/// same chokepoint that refreshes the Mac Dock badge), so an attached phone can
/// SET its app-icon badge to the authoritative total. The payload is just
/// `{"unread_count": Int}` — a count, never any terminal content. The phone
/// never does local badge arithmetic; every event sets the absolute total so
/// any drift self-heals on the next one.
public struct MobileNotificationBadgeEvent: Decodable, Sendable {
    /// The Mac's authoritative unread-notification count.
    public let unreadCount: Int?

    private enum CodingKeys: String, CodingKey {
        case unreadCount = "unread_count"
    }

    /// Decodes the payload, tolerating absent fields.
    /// - Parameter decoder: The JSON decoder for the event payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount)
    }

    /// Decode a `notification.badge` event from a raw JSON payload.
    /// - Parameter data: The event payload JSON.
    /// - Returns: The decoded event, or `nil` when the payload is malformed.
    public static func decode(_ data: Data) -> MobileNotificationBadgeEvent? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}
