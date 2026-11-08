import Bonsplit
import CmuxWorkspaces
import Foundation

/// Notification-pane creation and the shared one-per-workspace open path.
extension Workspace {
    @discardableResult
    func newNotificationsSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> NotificationsPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        let notificationsPanel = NotificationsPanel()
        panels[notificationsPanel.id] = notificationsPanel
        panelTitles[notificationsPanel.id] = notificationsPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: notificationsPanel.displayTitle,
            icon: notificationsPanel.displayIcon,
            kind: SurfaceKind.notifications.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: notificationsPanel.id)
            panelTitles.removeValue(forKey: notificationsPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: notificationsPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            notificationsPanel.id,
            paneId: paneId,
            kind: SurfaceKind.notifications.rawValue,
            origin: "notifications_tab",
            focused: shouldFocusNewTab
        )
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: notificationsPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return notificationsPanel
    }

    /// Focuses the workspace's notification tab or creates it in `paneId`.
    @discardableResult
    func openOrFocusNotificationsSurface(
        inPane paneId: PaneID,
        focus: Bool = true
    ) -> NotificationsPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        for (existingId, panel) in panels {
            guard let notificationsPanel = panel as? NotificationsPanel else { continue }
            if focus {
                focusPanel(existingId)
            }
            return notificationsPanel
        }
        return newNotificationsSurface(inPane: paneId, focus: focus)
    }
}
