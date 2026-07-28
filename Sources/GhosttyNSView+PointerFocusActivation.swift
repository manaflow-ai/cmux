import CmuxTerminalCore

extension GhosttyNSView {
    func activateContainerFocusFromPointerDown() {
        guard let terminalSurface else { return }

        switch terminalSurface.focusPlacement {
        case .workspace:
            AppDelegate.shared?.noteTerminalKeyboardFocusIntent(
                workspaceId: terminalSurface.tabId,
                panelId: terminalSurface.id,
                in: window
            )
        case .rightSidebarDock:
            DockSplitStore.focusPanelFromDockPointer(terminalSurface.id, window: window)
        }
    }

    func terminalPointerShouldForwardActivation() -> Bool {
        guard let terminalSurface else { return false }
        guard desiredFocus else { return false }

        let policy = TerminalPointerFocusActivationPolicy()
        switch terminalSurface.focusPlacement {
        case .workspace:
            return policy.shouldForwardToTerminal(
                currentPanelId: terminalSurface.id,
                focusedPanelId: terminalSurface.owningWorkspace()?.focusedPanelId
            )
        case .rightSidebarDock:
            return policy.shouldForwardToTerminal(
                currentPanelId: terminalSurface.id,
                focusedPanelId: DockSplitStore.liveStore(containingPanel: terminalSurface.id)?.focusedPanelId
            )
        }
    }
}
