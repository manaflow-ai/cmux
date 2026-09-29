import Foundation

public enum NotificationLevel: String, Sendable, Hashable, Codable {
    case info, warning, error
}

/// Retained unread marker on a tab (one per tab; a later one overwrites it).
public struct TabNotification: Sendable, Hashable, Decodable {
    public var notification: NotificationID
    public var unread: Bool
    public var level: NotificationLevel?
    /// Not serialized on `Tab.notification` by current daemons; the
    /// `list-notifications` ledger carries `created_at_ms`.
    public var createdAtMs: UInt64?

    public init(notification: NotificationID, unread: Bool, level: NotificationLevel? = nil, createdAtMs: UInt64? = nil) {
        self.notification = notification
        self.unread = unread
        self.level = level
        self.createdAtMs = createdAtMs
    }

    enum CodingKeys: String, CodingKey {
        case notification, unread, level
        case createdAtMs = "created_at_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notification = try c.decode(NotificationID.self, forKey: .notification)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        level = try? c.decodeIfPresent(NotificationLevel.self, forKey: .level)
        createdAtMs = try c.decodeIfPresent(UInt64.self, forKey: .createdAtMs)
    }
}
