import Foundation

/// The durable unread marker used for agent sessions.
enum AgentSessionUnreadEvent: Sendable {
    case turnFinished
    case needsInput
    case error
    case notification
}

extension Workspace {
    /// Records an agent event as unread when the panel is not visible in the
    /// selected workspace of the active window. Existing notification state
    /// already supplies the same attention signal, so it is not double-counted.
    func markAgentSessionUnread(panelId: UUID, event _: AgentSessionUnreadEvent) {
        guard panels[panelId] != nil else { return }
        guard !isAgentSessionPanelVisible(panelId) else { return }
        let hasWorkspaceNotification = AppDelegate.shared?.notificationStore?
            .hasUnreadNotification(forTabId: id, surfaceId: nil) ?? false
        guard !hasUnreadNotification(panelId: panelId), !hasWorkspaceNotification else { return }
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
    }

    private func isAgentSessionPanelVisible(_ panelId: UUID) -> Bool {
        guard let manager = owningTabManager,
              manager.selectedTabId == id,
              AppFocusState.isAppActive() else {
            return false
        }
        if focusedPanelId == panelId { return true }
        guard let paneId = paneId(forPanelId: panelId),
              let surfaceId = surfaceIdFromPanelId(panelId) else {
            return false
        }
        return bonsplitController.selectedTab(inPane: paneId)?.id == surfaceId
    }
}
