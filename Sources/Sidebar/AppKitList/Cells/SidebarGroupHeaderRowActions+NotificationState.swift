import Foundation

extension SidebarGroupHeaderRowActions {
    /// Snapshot of notification commands that are currently actionable.
    struct NotificationState {
        let canMarkRead: Bool
        let canMarkUnread: Bool
        let hasLatestNotifications: Bool
        let canMarkAllRead: Bool
        let canMarkAllUnread: Bool

        static let unavailable = Self(
            canMarkRead: false,
            canMarkUnread: false,
            hasLatestNotifications: false,
            canMarkAllRead: false,
            canMarkAllUnread: false
        )
    }
}
