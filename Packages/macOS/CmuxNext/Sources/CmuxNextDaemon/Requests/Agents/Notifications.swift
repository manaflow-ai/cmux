import Foundation

public struct NotifyRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var notification: NotificationID
    }
    public static let command = "notify"
    public var title: String
    public var body: String
    public var level: NotificationLevel?
    public var surface: SurfaceID?
    /// Who posts it (`notification-source-v1`): `cli`, `terminal`, `agent` or
    /// `daemon`; the daemon's default is `cli`.
    public var source: String?
    public init(title: String, body: String = "", level: NotificationLevel? = nil, surface: SurfaceID? = nil,
                source: String? = nil) {
        self.title = title
        self.body = body
        self.level = level
        self.surface = surface
        self.source = source
    }
}

/// Acknowledges a tab's notifications without selecting it
/// (`notification-ack-v1`): clears the unread marker durably and emits
/// `tab-changed` for each view whose marker cleared.
public struct AckTabNotificationsRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var cleared: Bool
        public var acknowledged: [String]
        /// Local feed items of the tab owned elsewhere (`feed-local-owner-v1`):
        /// `feed.moving` while handing off, `owner.unreachable` once moved.
        /// Nil on older daemons.
        public var refused: [Refused]?
        public init(surface: SurfaceID, cleared: Bool, acknowledged: [String], refused: [Refused]? = nil) {
            self.surface = surface
            self.cleared = cleared
            self.acknowledged = acknowledged
            self.refused = refused
        }
    }
    /// One local feed item the ack could not read.
    public struct Refused: Decodable, Sendable, Hashable {
        public var item: String
        public var code: String
        public var retryable: Bool
        public init(item: String, code: String, retryable: Bool = true) {
            self.item = item
            self.code = code
            self.retryable = retryable
        }
    }
    public static let command = "ack-tab-notifications"
    public var surface: SurfaceID
    public init(surface: SurfaceID) { self.surface = surface }
}

/// The retained ledger (at most 256), newest first (`notification-ack-v1`).
public struct ListNotificationsRequest: DaemonRequest {
    public struct Entry: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var subtitle: String?
        public var body: String
        public var level: NotificationLevel
        public var terminalID: TerminalID?
        public var surface: SurfaceID?
        public var createdAtMs: UInt64
        public var acknowledged: Bool
        enum CodingKeys: String, CodingKey {
            case id, title, subtitle, body, level, surface, acknowledged
            case terminalID = "terminal_id"
            case createdAtMs = "created_at_ms"
        }
    }
    public struct Response: Decodable, Sendable, Equatable {
        public var notifications: [Entry]
    }
    public static let command = "list-notifications"
    public var limit: Int?
    public init(limit: Int? = nil) { self.limit = limit }
}
