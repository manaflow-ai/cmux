public import Foundation

/// A single notification mirrored from the Mac's `TerminalNotificationStore`.
///
/// This is the iOS-facing value snapshot the notifications feed renders. It is a
/// plain `Sendable` value (no reference to any store) so it can cross the
/// `List`/`ForEach` snapshot boundary safely.
public struct MobileNotificationPreview: Identifiable, Equatable, Sendable {
    /// Stable notification identifier (the Mac notification's UUID string).
    public let id: String
    /// The workspace this notification belongs to. Equals the Mac's
    /// `TerminalNotification.tabId` and the `MobileWorkspacePreview.ID` raw
    /// value, so it maps directly onto the workspace open / deep-link path.
    public let workspaceID: String
    /// The terminal surface, when the notification was scoped to one.
    public let surfaceID: String?
    /// The notification title shown as the row's primary line.
    public let title: String
    /// The notification subtitle, shown under the title when non-empty.
    public let subtitle: String
    /// The notification body text.
    public let body: String
    /// Whether title/subtitle/body were redacted by the Mac privacy setting.
    public let isContentHidden: Bool
    /// When the notification fired (drives reverse-chron order + relative time).
    public let createdAt: Date
    /// Whether the user has read this notification (drives the unread badges).
    public var isRead: Bool

    /// Create a notification preview value.
    public init(
        id: String,
        workspaceID: String,
        surfaceID: String?,
        title: String,
        subtitle: String,
        body: String,
        isContentHidden: Bool,
        createdAt: Date,
        isRead: Bool
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.isContentHidden = isContentHidden
        self.createdAt = createdAt
        self.isRead = isRead
    }
}
