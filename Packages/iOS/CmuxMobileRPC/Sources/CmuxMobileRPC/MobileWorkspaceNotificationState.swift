/// Notification and unread state reported for a remote workspace.
public struct MobileWorkspaceNotificationState: Decodable, Sendable, Equatable {
    /// The authoritative workspace unread count on the host.
    public let unreadCount: Int
    /// Whether the host considers the workspace unread.
    public let hasUnread: Bool
    /// The latest notification identifier, when one exists.
    public let latestNotificationID: String?

    private enum CodingKeys: String, CodingKey {
        case unreadCount = "unread_count"
        case hasUnread = "has_unread"
        case latestNotificationID = "latest_notification_id"
    }
}
