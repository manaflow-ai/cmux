import AppKit
import CmuxHomeCore

extension AppDelegate {
    /// Opens the selected Chief conversation in the active window's movable
    /// right Dock, reusing the existing tab when it is already present.
    @discardableResult
    func openChiefInRightDock(
        conversationID: ConversationID,
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            return false
        }
        let dock = context.windowDockStore(notificationStore: notificationStore)
        guard let panelID = dock.openOrFocusChiefSurface(conversationID: conversationID, focus: true) else {
            return false
        }
        _ = focusRightSidebarInActiveMainWindow(
            mode: .dock,
            focusFirstItem: false,
            preferredWindow: context.window
        )
        dock.focusPanelFromDockInteraction(panelID, window: context.window)
        return true
    }

    /// Starts Chief at launch when `chief.enabled` is on, so the sidebar's
    /// Home row shows unread replies before Home is first opened, and wires
    /// the first-run rows that open a terminal or an agent.
    ///
    /// Starting is cheap on the main thread: it creates the store, and the
    /// owner loads the conversation logs on a background task (the store
    /// connects when they are in). No agent process runs until the user
    /// sends a message.
    func startChiefIfEnabled() {
        guard ChiefSettings.isEnabled else { return }
        let service = ChiefService.shared
        service.onFirstRunAction = { [weak self] action in
            self?.performChiefFirstRunAction(action)
        }
        service.start()
    }

    /// Leaves Chief Home in `tabManager`'s window before a user action that
    /// creates content in its selected workspace (new tab, split, browser), so
    /// the result is never made in a workspace the user cannot see.
    func leaveChiefHome(in tabManager: TabManager?) {
        guard let tabManager, let context = mainWindowContext(for: tabManager) else { return }
        ChiefHomeNavigation(sidebarSelectionState: context.sidebarSelectionState).leave()
    }

    /// A first-run row: a new workspace (leaving Home), with the user's agent
    /// started in it for "Start an agent".
    private func performChiefFirstRunAction(_ action: ChiefFirstRunAction) {
        guard let tabManager else { return }
        switch action {
        case .openTerminal:
            _ = tabManager.addWorkspaceIfActive(select: true)
        case .startAgent:
            let command = ChiefSettings.harness == .codex ? "codex" : "claude"
            _ = tabManager.addWorkspaceIfActive(initialTerminalInput: command + "\n", select: true)
        }
    }
}
