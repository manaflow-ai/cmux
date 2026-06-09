public import Foundation

/// A single notification mirrored from the Mac's `TerminalNotificationStore`.
///
/// This is the iOS-facing value snapshot the notifications feed renders and the
/// phone-side store derives unread counts from. It is a plain `Sendable` value
/// (no reference to any store) so it can cross the `List`/`ForEach` snapshot
/// boundary safely.
public struct MobileNotificationPreview: Identifiable, Equatable, Sendable {
    /// Stable notification identifier (the Mac notification's UUID string).
    public let id: String
    /// The workspace this notification belongs to. Equals the Mac's
    /// `TerminalNotification.tabId` and the `MobileWorkspacePreview.ID` raw
    /// value, so it maps directly onto the workspace open / deep-link path.
    public let workspaceID: String
    /// The owning workspace's display name, shown on the feed row so the user can
    /// tell which workspace/Mac the notification came from. `nil` when the
    /// workspace has closed or has no title.
    public let workspaceName: String?
    /// The terminal surface, when the notification was scoped to one.
    public let surfaceID: String?
    /// The notification title shown as the row's primary line.
    public let title: String
    /// The notification subtitle, shown under the title when non-empty.
    public let subtitle: String
    /// The notification body text.
    public let body: String
    /// When the notification fired (drives reverse-chron order + relative time).
    public let createdAt: Date
    /// Whether the user has read this notification (drives the unread badges).
    public var isRead: Bool

    /// Create a notification preview value.
    public init(
        id: String,
        workspaceID: String,
        workspaceName: String?,
        surfaceID: String?,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.surfaceID = surfaceID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
    }
}

/// Typed decoder for the `mobile.notifications.list` RPC result.
///
/// The wire shape is snake_case (the Mac emits it that way, matching
/// `workspace.list`); `CodingKeys` map it onto camelCase Swift properties
/// without changing the wire. The list is newest-first as produced by the Mac.
public struct MobileNotificationsListResponse: Decodable, Sendable {
    /// One notification row on the wire.
    public struct Notification: Decodable, Sendable {
        /// Stable notification identifier.
        public let id: String
        /// The owning workspace's id (the Mac's `tabId`).
        public let workspaceID: String
        /// The owning workspace's display name, or `nil` when unavailable.
        public let workspaceName: String?
        /// The terminal surface id, when scoped to one; otherwise `nil`.
        public let surfaceID: String?
        /// The notification title.
        public let title: String
        /// The notification subtitle.
        public let subtitle: String
        /// The notification body.
        public let body: String
        /// Creation time as Unix epoch seconds.
        public let createdAt: Double
        /// Whether the notification has been read.
        public let isRead: Bool

        private enum CodingKeys: String, CodingKey {
            case id
            case workspaceID = "workspace_id"
            case workspaceName = "workspace_name"
            case surfaceID = "surface_id"
            case title
            case subtitle
            case body
            case createdAt = "created_at"
            case isRead = "is_read"
        }
    }

    /// The recent notifications, newest-first as produced by the Mac.
    public let notifications: [Notification]

    private enum CodingKeys: String, CodingKey {
        case notifications
    }

    /// Decode a notifications-list response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileNotificationsListResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }

    /// Map the decoded wire rows into iOS-facing value previews.
    public func previews() -> [MobileNotificationPreview] {
        notifications.map { row in
            MobileNotificationPreview(
                id: row.id,
                workspaceID: row.workspaceID,
                workspaceName: row.workspaceName,
                surfaceID: row.surfaceID,
                title: row.title,
                subtitle: row.subtitle,
                body: row.body,
                createdAt: Date(timeIntervalSince1970: row.createdAt),
                isRead: row.isRead
            )
        }
    }
}
