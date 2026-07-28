import CmuxTerminalCore

extension GhosttyNSView {
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
                focusedPanelId: AppDelegate.shared?.windowDockContainingPanel(terminalSurface.id)?.focusedPanelId
            )
        }
    }
}
