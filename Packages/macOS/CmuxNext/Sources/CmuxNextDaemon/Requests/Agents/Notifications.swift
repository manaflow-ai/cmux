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
    }
    public static let command = "ack-tab-notifications"
    public static let requiredCapability: String? = DaemonCapabilities.shared.notificationAck
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
        /// `notification-program-status-v1`; nil for other notifications.
        public var programStatus: NotificationProgramStatus?
        enum CodingKeys: String, CodingKey {
            case id, title, subtitle, body, level, surface, acknowledged
            case terminalID = "terminal_id"
            case createdAtMs = "created_at_ms"
            case programStatus = "program_status"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
            body = try c.decode(String.self, forKey: .body)
            level = try c.decode(NotificationLevel.self, forKey: .level)
            terminalID = try c.decodeIfPresent(TerminalID.self, forKey: .terminalID)
            surface = try c.decodeIfPresent(SurfaceID.self, forKey: .surface)
            createdAtMs = try c.decode(UInt64.self, forKey: .createdAtMs)
            acknowledged = try c.decode(Bool.self, forKey: .acknowledged)
            programStatus = try? c.decodeIfPresent(NotificationProgramStatus.self, forKey: .programStatus)
        }
    }
    public struct Response: Decodable, Sendable, Equatable {
        public var notifications: [Entry]
    }
    public static let command = "list-notifications"
    public static let requiredCapability: String? = DaemonCapabilities.shared.notificationAck
    public var limit: Int?
    public init(limit: Int? = nil) { self.limit = limit }
}
