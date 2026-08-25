import AppKit
import Foundation

@MainActor
extension Workspace {
    /// Installs visual-BEL routing at the terminal's authoritative owner.
    /// Ownership changes replace this callback during surface transfer, so a
    /// background bell never needs an app-wide surface or focus scan.
    func installTerminalVisualBellRouting(for terminalPanel: TerminalPanel) {
        terminalPanel.surface.onExplicitInput = { [weak self, weak terminalPanel] in
            guard let self, let terminalPanel else { return }
            self.owningTabManager?.dismissNotificationOnTerminalInteraction(
                tabId: self.id,
                surfaceId: terminalPanel.id
            )
        }
        terminalPanel.surface.onVisualBell = { [weak self, weak terminalPanel] in
            guard let self, let terminalPanel,
                  let target = self.surfaceOwnershipTarget(for: terminalPanel.id),
                  let ownedTerminal = target.panel as? TerminalPanel,
                  ownedTerminal === terminalPanel else {
                return
            }
            let ownerWindow = self.owningTabManager?.window
            let ownsActiveFocus = AppFocusState.isAppFocused()
                && ownerWindow?.isKeyWindow == true
                && AppDelegate.shared?.ownsMainPanelKeyboardFocus(
                    workspaceId: self.id,
                    containerPanelId: target.containerPanelID,
                    surfaceId: target.surfaceID,
                    in: ownerWindow
                ) == true
            let response = TerminalVisualBellResponse.resolve(
                ownsActiveFocus: ownsActiveFocus,
                isManuallyUnread: self.manualUnreadPanelIds.contains(target.containerPanelID)
            )
            if response.marksUnread {
                self.markPanelUnread(target.containerPanelID)
            }
            if response.flashes {
                ownedTerminal.triggerFlash(reason: .notificationArrival)
            }
        }
    }

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

/// What one terminal BEL does, given who owns keyboard focus.
///
/// Ghostty's `attention` bell feature asks for attention only when the surface
/// is not the one being used. A bell in the terminal you are typing into —
/// readline beeping at the end of the line, `less` at the last page — is
/// feedback to you, not news from a background pane, so it must not render as
/// a notification arriving (the same flash `cmux notify` produces).
struct TerminalVisualBellResponse: Equatable {
    let marksUnread: Bool
    let flashes: Bool

    static func resolve(ownsActiveFocus: Bool, isManuallyUnread: Bool) -> TerminalVisualBellResponse {
        if ownsActiveFocus {
            return TerminalVisualBellResponse(marksUnread: false, flashes: false)
        }
        return TerminalVisualBellResponse(marksUnread: !isManuallyUnread, flashes: true)
    }
}
