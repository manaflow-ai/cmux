import Foundation

@MainActor
extension TerminalNotificationStore {
    private static let workspaceContextMenuNotificationLimit = 50

    func notifications(forTabIds tabIds: [UUID]) -> [TerminalNotification] {
        guard !tabIds.isEmpty else { return [] }
        let targetIds = Set(tabIds)
        let sorted = notifications
            .filter { targetIds.contains($0.tabId) }
            .sorted(by: Self.notificationSortPrecedes)
        return Array(sorted.prefix(Self.workspaceContextMenuNotificationLimit))
    }

    /// Marks read only the notifications recorded against the workspace itself,
    /// with no surface and no panel, such as cmux's own memory-pressure alert.
    /// Surface-scoped notifications, every manual or restored unread indicator,
    /// and in-flight policy work stay as they are, so reading the workspace's own
    /// notifications cannot swallow another pane's unread state.
    func markWorkspaceLevelNotificationsRead(forTabId tabId: UUID) {
        // History keeps records the active list has already dropped, so the feed
        // is marked by target while the active notifications are marked by id:
        // that is the path which also withdraws their delivered Mac banners.
        notificationFeedHistory.markRead(inWorkspace: tabId, surfaceId: nil)
        let activeIDs = Set(
            notifications.lazy
                .filter { !$0.isRead && $0.matches(tabId: tabId, surfaceId: nil) }
                .map(\.id)
        )
        guard !activeIDs.isEmpty else { return }
        markNotificationFeedRead(ids: activeIDs)
    }
}
