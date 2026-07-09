public import Foundation

/// Immutable per-workspace unread projection rendered by the sidebar. Equatable
/// so the coalesced model only republishes when a workspace's badge or
/// latest-message text actually changes. `latestNotificationText` is the
/// trimmed body-or-title of the latest notification (read or unread) and is NOT
/// gated by the `showsSidebarNotificationMessage` setting; the sidebar applies
/// that gate at its read site.
public struct SidebarWorkspaceUnreadSummary: Equatable {
    /// Number of unread notifications attributed to the workspace.
    public var unreadCount: Int
    /// Trimmed body-or-title of the latest notification, read or unread.
    public var latestNotificationText: String?

    /// Creates a per-workspace unread summary.
    public init(unreadCount: Int, latestNotificationText: String?) {
        self.unreadCount = unreadCount
        self.latestNotificationText = latestNotificationText
    }
}
