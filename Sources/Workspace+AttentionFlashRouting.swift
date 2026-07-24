import Foundation

@MainActor
extension Workspace {
    func triggerFocusFlash(panelId: UUID) {
        requestAttentionFlash(panelId: panelId, reason: .navigation)
    }

    func triggerUserInitiatedFocusFlash(panelId: UUID) {
        requestAttentionFlash(panelId: panelId, reason: .userInitiated)
    }

    func triggerNotificationFocusFlash(
        panelId: UUID,
        requiresSplit: Bool = false,
        shouldFocus: Bool = true
    ) {
        if AppDelegate.shared?.routeNotificationAttentionFlash(
            workspaceID: id,
            panelID: panelId,
            reason: .notificationArrival,
            requiresSplit: requiresSplit,
            shouldFocus: shouldFocus
        ) == true {
            return
        }
        guard terminalPanel(for: panelId) != nil else { return }
        if shouldFocus {
            focusPanel(panelId)
        }
        let isSplit = bonsplitController.allPaneIds.count > 1 || panels.count > 1
        if requiresSplit && !isSplit {
            return
        }
        requestAttentionFlash(panelId: panelId, reason: .notificationArrival)
    }

    func triggerNotificationDismissFlash(panelId: UUID) {
        if AppDelegate.shared?.routeNotificationAttentionFlash(
            workspaceID: id,
            panelID: panelId,
            reason: .notificationDismiss
        ) == true {
            return
        }
        guard terminalPanel(for: panelId) != nil else { return }
        requestAttentionFlash(panelId: panelId, reason: .notificationDismiss)
    }

    func triggerUnreadIndicatorDismissFlash(panelId: UUID) {
        if AppDelegate.shared?.routeNotificationAttentionFlash(
            workspaceID: id,
            panelID: panelId,
            reason: .unreadIndicatorDismiss
        ) == true {
            return
        }
        guard terminalPanel(for: panelId) != nil else { return }
        requestAttentionFlash(panelId: panelId, reason: .unreadIndicatorDismiss)
    }

    func triggerDebugFlash(panelId: UUID) {
        guard panels[panelId] != nil else { return }
        focusPanel(panelId)
        requestAttentionFlash(panelId: panelId, reason: .debug)
    }
}
