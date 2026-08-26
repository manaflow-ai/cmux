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

        switch terminalSurface.focusPlacement {
        case .workspace:
            guard let workspace = terminalSurface.owningWorkspace() else { return false }
            return workspace.isFocusedTerminalInputSurface(terminalSurface.id)
        case .rightSidebarDock:
            return TerminalPointerFocusActivationPolicy().shouldForwardToTerminal(
                currentPanelId: terminalSurface.id,
                focusedPanelId: DockSplitStore.liveStore(containingPanel: terminalSurface.id)?.focusedPanelId
            )
        }
    }
}
