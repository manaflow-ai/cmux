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

    func storeHasDismissibleState(workspaceId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasDismissibleState(forTabId: workspaceId) ?? false
    }

    func workspaceHasDismissiblePanelState(workspaceId: UUID) -> Bool {
        guard let workspace = workspacesById[workspaceId] else { return false }
        return !workspace.manualUnreadPanelIds.isEmpty || workspace.hasAnyRestoredUnreadPanelIndicator
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

    func storeHasPendingNotification(workspaceId: UUID, surfaceId: UUID?) -> Bool {
        AppDelegate.shared?.notificationStore?
            .hasPendingNotification(forTabId: workspaceId, surfaceId: surfaceId) ?? false
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
        // SessionAutosaveNotificationIndex assembles buckets in retained feed
        // order. Hash that deterministic order directly instead of sorting
        // every notification bucket on each autosave tick.
        for notification in notifications {
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

    nonisolated static func uuidSortPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        let left = lhs.uuid
        let right = rhs.uuid
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        if left.2 != right.2 { return left.2 < right.2 }
        if left.3 != right.3 { return left.3 < right.3 }
        if left.4 != right.4 { return left.4 < right.4 }
        if left.5 != right.5 { return left.5 < right.5 }
        if left.6 != right.6 { return left.6 < right.6 }
        if left.7 != right.7 { return left.7 < right.7 }
        if left.8 != right.8 { return left.8 < right.8 }
        if left.9 != right.9 { return left.9 < right.9 }
        if left.10 != right.10 { return left.10 < right.10 }
        if left.11 != right.11 { return left.11 < right.11 }
        if left.12 != right.12 { return left.12 < right.12 }
        if left.13 != right.13 { return left.13 < right.13 }
        if left.14 != right.14 { return left.14 < right.14 }
        if left.15 != right.15 { return left.15 < right.15 }
        return false
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
