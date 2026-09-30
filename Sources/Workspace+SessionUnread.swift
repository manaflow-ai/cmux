import Foundation

/// The durable unread marker used for agent sessions.
enum AgentSessionUnreadEvent: Sendable {
    case turnFinished
    case needsInput
    case error
    case notification
}

extension Workspace {
    func markVisibleSessionUnreadRead() {
        for panelId in panels.keys {
            markVisibleAgentSessionRead(panelId: panelId)
        }
        for mirror in remoteTmuxWindowMirrors.values {
            for surfaceId in mirror.surfaceIDsInLayoutOrder {
                markVisibleNotificationRead(surfaceId: surfaceId)
            }
        }
    }

    func markVisibleNotificationRead(surfaceId: UUID) {
        guard let manager = owningTabManager,
              manager.selectedTabId == id,
              manager.window?.isVisible == true,
              manager.window?.isKeyWindow == true,
              AppFocusState.isAppActive() else {
            return
        }
        _ = manager.dismissNotificationOnVisiblePanel(tabId: id, surfaceId: surfaceId)
    }

    /// Records an agent event as unread when the panel is not visible in the
    /// selected workspace of the active window. Existing notification state
    /// already supplies the same attention signal, so it is not double-counted.
    func markAgentSessionUnread(panelId: UUID, event _: AgentSessionUnreadEvent) {
        guard panels[panelId] != nil else { return }
        guard !isAgentSessionPanelVisible(panelId) else { return }
        guard !hasUnreadNotification(panelId: panelId) else { return }
        restorePanelUnreadIndicator(panelId, contributesToWorkspaceUnread: true)
    }

    /// Clears only the agent-session marker for a panel. User-created manual
    /// unread state and notification rows have their own explicit policies.
    func markAgentSessionRead(panelId: UUID) {
        clearRestoredUnreadIndicator(panelId: panelId)
    }

    /// View seam used by the pane host; inactive or hidden workspaces do not
    /// count as having been seen.
    func markVisibleAgentSessionRead(panelId: UUID) {
        guard isAgentSessionPanelVisible(panelId) else { return }
        markAgentSessionRead(panelId: panelId)
        guard let surfaceId = surfaceIdFromPanelId(panelId)?.uuid else { return }
        owningTabManager?.dismissNotificationOnVisiblePanel(tabId: id, surfaceId: surfaceId)
    }

    private func isAgentSessionPanelVisible(_ panelId: UUID) -> Bool {
        guard let manager = owningTabManager,
              manager.selectedTabId == id,
              let window = manager.window,
              window.isVisible,
              window.isKeyWindow,
              AppFocusState.isAppActive(),
              let paneId = paneId(forPanelId: panelId) else {
            return false
        }
        if let zoomedPaneId = bonsplitController.zoomedPaneId,
           zoomedPaneId != paneId {
            return false
        }
        if focusedPanelId == panelId { return true }
        guard let surfaceId = surfaceIdFromPanelId(panelId) else {
            return false
        }
        return bonsplitController.selectedTab(inPane: paneId)?.id == surfaceId
    }
}
