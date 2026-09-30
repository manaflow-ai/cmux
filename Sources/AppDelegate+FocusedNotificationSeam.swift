import Bonsplit
import CmuxNotifications
import Foundation

@MainActor
extension AppDelegate {
    func windowDockSurfaceIsUnread(_ target: WindowDockUnreadTarget) -> Bool {
        guard let notificationStore else { return false }
        return notificationStore.hasManualUnread(
            forTabId: target.windowId,
            surfaceId: target.surfaceId
        ) || notificationStore.hasVisibleNotificationIndicator(
            forTabId: target.windowId,
            surfaceId: target.surfaceId
        )
    }

    func markWindowDockSurfaceUnread(_ target: WindowDockUnreadTarget) {
        notificationStore?.markWindowDockSurfaceUnread(
            windowId: target.windowId,
            surfaceId: target.surfaceId
        )
    }

    func clearWindowDockSurfaceUnread(_ target: WindowDockUnreadTarget) {
        notificationStore?.markRead(
            forTabId: target.windowId,
            surfaceId: target.surfaceId
        )
        notificationStore?.clearFocusedReadIndicator(
            forTabId: target.windowId,
            surfaceId: target.surfaceId
        )
    }

    func markLatestWindowDockNotificationAsOldestUnread(
        _ target: WindowDockUnreadTarget
    ) -> UUID? {
        notificationStore?.markLatestWindowDockNotificationAsOldestUnread(
            windowId: target.windowId,
            surfaceId: target.surfaceId
        )
    }

    func focusedPanel(forTabId tabId: UUID, surfaceId: UUID?) -> FocusedPanel? {
        guard let surfaceId,
              let workspace = workspaceFor(tabId: tabId) else {
            return nil
        }
        let panelId: UUID?
        if workspace.panels[surfaceId] != nil {
            panelId = surfaceId
        } else {
            panelId = workspace.panelIdFromSurfaceId(TabID(uuid: surfaceId))
        }
        guard let panelId,
              workspace.panels[panelId] != nil else {
            return nil
        }
        return FocusedPanel(tabId: tabId, panelId: panelId)
    }

    func panelHasRestoredUnread(_ panel: FocusedPanel) -> Bool {
        workspaceFor(tabId: panel.tabId)?.hasRestoredUnreadIndicator(panelId: panel.panelId) ?? false
    }

    func workspaceHasContributingRestoredUnread(_ panel: FocusedPanel) -> Bool {
        workspaceFor(tabId: panel.tabId)?.hasWorkspaceContributingRestoredUnreadIndicator ?? false
    }

    func panelIsManualUnread(_ panel: FocusedPanel) -> Bool {
        workspaceFor(tabId: panel.tabId)?.manualUnreadPanelIds.contains(panel.panelId) ?? false
    }

    func panelIsRepresentativeForWorkspaceManualUnread(_ panel: FocusedPanel) -> Bool {
        workspaceFor(tabId: panel.tabId)?.representativePanelIdForWorkspaceManualUnread() == panel.panelId
    }

    func hasVisibleNotificationIndicator(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        notificationStore?.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: surfaceId) ?? false
    }

    func storeHasManualUnread(forTabId tabId: UUID) -> Bool {
        notificationStore?.hasManualUnread(forTabId: tabId) ?? false
    }

    func storeHasRestoredUnread(forTabId tabId: UUID) -> Bool {
        notificationStore?.hasRestoredUnreadIndicator(forTabId: tabId) ?? false
    }

    func workspaceIsUnread(forTabId tabId: UUID) -> Bool {
        notificationStore?.workspaceIsUnread(forTabId: tabId) ?? false
    }

    func storeMarkRead(forTabId tabId: UUID) {
        notificationStore?.markRead(forTabId: tabId)
    }

    func storeMarkUnread(forTabId tabId: UUID) {
        notificationStore?.markUnread(forTabId: tabId)
    }

    func storeClearManualUnread(forTabId tabId: UUID) {
        _ = notificationStore?.clearManualUnread(forTabId: tabId)
    }

    func markPanelRead(_ panel: FocusedPanel) {
        workspaceFor(tabId: panel.tabId)?.markPanelRead(panel.panelId)
    }

    func markPanelUnread(_ panel: FocusedPanel) {
        workspaceFor(tabId: panel.tabId)?.markPanelUnread(panel.panelId)
    }

    func markLatestNotificationAsOldestUnread(forTabId tabId: UUID, surfaceId: UUID?) -> UUID? {
        notificationStore?.markLatestNotificationAsOldestUnread(forTabId: tabId, surfaceId: surfaceId)
    }
}
