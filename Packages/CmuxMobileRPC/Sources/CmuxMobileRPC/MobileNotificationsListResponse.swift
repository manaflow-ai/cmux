public import Foundation

/// A single notification mirrored from the Mac's `TerminalNotificationStore`.
///
/// This is the iOS-facing value snapshot the notifications feed renders and the
/// phone-side store derives unread counts from. It is a plain `Sendable` value
/// (no reference to any store) so it can cross the `List`/`ForEach` snapshot
/// boundary safely.
public struct MobileNotificationPreview: Identifiable, Equatable, Sendable {
    public let id: String
    /// The workspace this notification belongs to. Equals the Mac's
    /// `TerminalNotification.tabId` and the `MobileWorkspacePreview.ID` raw
    /// value, so it maps directly onto the workspace open / deep-link path.
    public let workspaceID: String
    /// The terminal surface, when the notification was scoped to one.
    public let surfaceID: String?
    public let title: String
    public let subtitle: String
    public let body: String
    public let createdAt: Date
    public var isRead: Bool

    public init(
        id: String,
        workspaceID: String,
        surfaceID: String?,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool
    ) {
        self.id = id
        self.workspaceID = workspaceID
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
        public let id: String
        public let workspaceID: String
        public let surfaceID: String?
        public let title: String
        public let subtitle: String
        public let body: String
        /// Creation time as Unix epoch seconds.
        public let createdAt: Double
        public let isRead: Bool

        private enum CodingKeys: String, CodingKey {
            case id
            case workspaceID = "workspace_id"
            case surfaceID = "surface_id"
            case title
            case subtitle
            case body
            case createdAt = "created_at"
            case isRead = "is_read"
        }
    }

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
