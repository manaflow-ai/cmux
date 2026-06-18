import CmuxNotifications
import Foundation

/// The window-side host for the CmuxNotifications dismissal model: snapshot
/// reads of selection/panel/unread state and the synchronous indicator
/// mutations the legacy `dismissNotification` flow performed inline.
/// Lookups mirror the legacy optional-chained `tabs.first(where:)` reads,
/// so a gone workspace/panel makes every read `false`/`nil` and every
/// mutation a no-op.
extension TabManager: NotificationDismissalHosting {
    var selectedWorkspaceId: UUID? {
        selectedTabId
    }

    var isAppActive: Bool {
        AppFocusState.isAppActive()
    }

    var hasNotificationStore: Bool {
        AppDelegate.shared?.notificationStore != nil
    }

    // focusedPanelId(in:) is already witnessed by the SidebarGitHosting
    // conformance (TabManager+SidebarGitHosting.swift); one declaration
    // satisfies both seams.

    func panelId(forSurfaceOrPanelId surfaceId: UUID, in workspaceId: UUID) -> UUID? {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return nil }
        return panelId(forSurfaceOrPanelId: surfaceId, in: workspace)
    }

    func workspaceHasManualPanelUnread(workspaceId: UUID, panelId: UUID) -> Bool {
        tabs.first(where: { $0.id == workspaceId })?.manualUnreadPanelIds.contains(panelId) ?? false
    }

    func workspaceHasRestoredPanelUnread(workspaceId: UUID, panelId: UUID) -> Bool {
        tabs.first(where: { $0.id == workspaceId })?.hasRestoredUnreadIndicator(panelId: panelId) ?? false
    }

    func storeHasManualUnread(workspaceId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasManualUnread(forTabId: workspaceId) ?? false
    }

    func storeHasRestoredUnreadIndicator(workspaceId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasRestoredUnreadIndicator(forTabId: workspaceId) ?? false
    }

    func storeHasUnreadNotification(workspaceId: UUID, surfaceId: UUID?) -> Bool {
        AppDelegate.shared?.notificationStore?.hasUnreadNotification(forTabId: workspaceId, surfaceId: surfaceId) ?? false
    }

    func storeHasVisibleNotificationIndicator(workspaceId: UUID, surfaceId: UUID?) -> Bool {
        AppDelegate.shared?.notificationStore?
            .hasVisibleNotificationIndicator(forTabId: workspaceId, surfaceId: surfaceId) ?? false
    }

    func storeMarkRead(workspaceId: UUID, surfaceId: UUID?) {
        AppDelegate.shared?.notificationStore?.markRead(forTabId: workspaceId, surfaceId: surfaceId)
    }

    @discardableResult
    func storeClearManualUnread(workspaceId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.clearManualUnread(forTabId: workspaceId) ?? false
    }

    @discardableResult
    func storeClearRestoredUnreadIndicator(workspaceId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.clearRestoredUnreadIndicator(forTabId: workspaceId) ?? false
    }

    func storeClearFocusedReadIndicator(workspaceId: UUID, surfaceId: UUID?) {
        AppDelegate.shared?.notificationStore?.clearFocusedReadIndicator(forTabId: workspaceId, surfaceId: surfaceId)
    }

    func workspaceClearManualUnread(workspaceId: UUID, panelId: UUID) {
        tabs.first(where: { $0.id == workspaceId })?.clearManualUnread(panelId: panelId)
    }

    func workspaceClearRestoredUnreadIndicator(workspaceId: UUID, panelId: UUID) {
        tabs.first(where: { $0.id == workspaceId })?.clearRestoredUnreadIndicator(panelId: panelId)
    }

    func workspaceTriggerNotificationDismissFlash(workspaceId: UUID, panelId: UUID) {
        tabs.first(where: { $0.id == workspaceId })?.triggerNotificationDismissFlash(panelId: panelId)
    }

    func workspaceTriggerUnreadIndicatorDismissFlash(workspaceId: UUID, panelId: UUID) {
        tabs.first(where: { $0.id == workspaceId })?.triggerUnreadIndicatorDismissFlash(panelId: panelId)
    }
}
