public import Foundation

/// Derived, read-only indexes computed from the full notification list.
///
/// Pure value projection of `[TerminalNotification]`: the total unread count,
/// per-workspace unread counts, the set of (workspace, surface) pairs that hold
/// unread notifications, and the latest (and latest-unread) notification per
/// workspace. Rebuilt wholesale whenever the notification list changes, so it
/// reaches into no live state and lives beside ``TerminalNotification`` in the
/// notifications package.
public struct NotificationIndexes: Sendable {
    /// Total number of unread notifications across all workspaces.
    public private(set) var unreadCount = 0
    /// Number of unread notifications keyed by workspace (tab) id.
    public private(set) var unreadCountByTabId: [UUID: Int] = [:]
    /// The set of (workspace, surface) pairs with at least one unread notification.
    public private(set) var unreadByTabSurface = Set<TabSurfaceKey>()
    /// The most recent unread notification per workspace (tab) id.
    public private(set) var latestUnreadByTabId: [UUID: TerminalNotification] = [:]
    /// The most recent notification (read or unread) per workspace (tab) id.
    public private(set) var latestByTabId: [UUID: TerminalNotification] = [:]

    /// Creates an empty index set.
    public init() {}

    /// Builds the indexes from the given notification list. The list is expected
    /// in display order (newest first), so the first notification seen for a
    /// workspace becomes that workspace's latest.
    public init(notifications: [TerminalNotification]) {
        for notification in notifications {
            if latestByTabId[notification.tabId] == nil {
                latestByTabId[notification.tabId] = notification
            }
            guard !notification.isRead else { continue }
            unreadCount += 1
            unreadCountByTabId[notification.tabId, default: 0] += 1
            unreadByTabSurface.insert(
                TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
            )
            if let panelId = notification.panelId, panelId != notification.surfaceId {
                unreadByTabSurface.insert(
                    TabSurfaceKey(tabId: notification.tabId, surfaceId: panelId)
                )
            }
            if latestUnreadByTabId[notification.tabId] == nil {
                latestUnreadByTabId[notification.tabId] = notification
            }
        }
    }
}
