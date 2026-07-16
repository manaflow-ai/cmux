import Foundation

/// Parent-owned immutable values consumed by the workspace sidebar's lazy rows.
///
/// The dictionaries are cheap value projections built before `LazyVStack`.
/// Notification filtering and row/action construction remain lazy and operate
/// only on these copied values, never on observable stores.
struct SidebarWorkspaceRowsSnapshot {
    private static let contextMenuNotificationLimit = 50

    let workspaceRowsById: [UUID: SidebarWorkspaceRowInput]
    let groupRowsById: [UUID: SidebarWorkspaceGroupRowSnapshot]
    let selectedContextTargetIds: [UUID]
    let anchorWorkspaceIds: Set<UUID>
    let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
    let canCreateEmptyGroup: Bool
    let unreadSummariesByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary]
    let notifications: [TerminalNotification]
    let windowMoveTargets: [SidebarWorkspaceWindowMoveTarget]

    func canMarkRead(workspaceIds: [UUID]) -> Bool {
        workspaceIds.contains { unreadCount(workspaceId: $0) > 0 }
    }

    func canMarkUnread(workspaceIds: [UUID]) -> Bool {
        workspaceIds.contains { unreadCount(workspaceId: $0) == 0 }
    }

    func hasNotification(workspaceIds: [UUID]) -> Bool {
        guard !workspaceIds.isEmpty else { return false }
        let targetIds = Set(workspaceIds)
        return notifications.contains { targetIds.contains($0.tabId) }
    }

    @MainActor
    func contextMenuNotifications(workspaceIds: [UUID]) -> [TerminalNotification] {
        guard !workspaceIds.isEmpty else { return [] }
        let targetIds = Set(workspaceIds)
        return Array(
            notifications
                .filter { targetIds.contains($0.tabId) }
                .sorted(by: TerminalNotificationStore.notificationSortPrecedes)
                .prefix(Self.contextMenuNotificationLimit)
        )
    }

    private func unreadCount(workspaceId: UUID) -> Int {
        unreadSummariesByWorkspaceId[workspaceId]?.unreadCount ?? 0
    }
}
