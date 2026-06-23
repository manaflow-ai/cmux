/// One notification row on the `mobile.notifications.list` wire response.
public struct MobileNotificationListRow: Decodable, Sendable {
    /// Stable notification identifier.
    public let id: String
    /// The owning workspace's id (the Mac's `tabId`).
    public let workspaceID: String
    /// The terminal surface id, when scoped to one; otherwise `nil`.
    public let surfaceID: String?
    /// The notification title.
    public let title: String
    /// The notification subtitle.
    public let subtitle: String
    /// The notification body.
    public let body: String
    /// Whether title/subtitle/body were redacted by the Mac privacy setting.
    public let isContentHidden: Bool
    /// Creation time as Unix epoch seconds.
    public let createdAt: Double
    /// Whether the notification has been read.
    public let isRead: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case title
        case subtitle
        case body
        case isContentHidden = "is_content_hidden"
        case createdAt = "created_at"
        case isRead = "is_read"
    }
}
