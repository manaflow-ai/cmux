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
    public init(title: String, body: String = "", level: NotificationLevel? = nil, surface: SurfaceID? = nil) {
        self.title = title
        self.body = body
        self.level = level
        self.surface = surface
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
