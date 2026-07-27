import Bonsplit
import CmuxNotifications
import Foundation

@MainActor
extension AppDelegate {
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
