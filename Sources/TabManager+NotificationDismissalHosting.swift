import CmuxNotifications
import CmuxSettings
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

    func focusedSurfaceId(in workspaceId: UUID) -> UUID? {
        focusedSurfaceId(for: workspaceId)
    }

    // Cache the catalog section so reading the flag does not re-init every
    // `SettingCatalog` section on each call (the read is gated to the
    // workspace-visibility dismiss path, never per-keystroke, but caching keeps
    // it allocation-free anyway — same pattern as `NotificationSettingsFileMapping`).
    private static let notificationsSettings = NotificationsCatalogSection()

    var suppressOnlyFocusedSurface: Bool {
        UserDefaultsSettingsClient(defaults: .standard)
            .value(for: Self.notificationsSettings.suppressOnlyFocusedSurface)
    }

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

    /// Notification hashing for session autosave extracted because
    /// `TabManager.swift` sits at its file-length budget.
    nonisolated static func hashNotifications(
        _ notifications: [TerminalNotification],
        into hasher: inout Hasher
    ) {
        hasher.combine(notifications.count)
        for notification in notifications.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hasher.combine(notification.id)
            hasher.combine(notification.title)
            hasher.combine(notification.subtitle)
            hasher.combine(notification.body)
            hasher.combine(notification.createdAt.timeIntervalSince1970)
            hasher.combine(notification.isRead)
            hasher.combine(notification.paneFlash)
            hasher.combine(notification.panelId)
            hasher.combine(notification.clickAction)
        }
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
