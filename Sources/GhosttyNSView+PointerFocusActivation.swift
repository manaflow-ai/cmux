import CmuxTerminalCore

extension GhosttyNSView {
    func terminalPointerShouldForwardActivation() -> Bool {
        TerminalPointerFocusActivationPolicy().shouldForwardToTerminal(
            wasFocusedBeforePointerDown: terminalWasFocusedBeforePointerDown()
        )
    }

    private func terminalWasFocusedBeforePointerDown() -> Bool {
        guard let terminalSurface else { return true }
        guard desiredFocus else { return false }

        switch terminalSurface.focusPlacement {
        case .workspace:
            return terminalSurface.owningWorkspace().map { $0.focusedPanelId == terminalSurface.id } ?? true
        case .rightSidebarDock:
            guard let dock = AppDelegate.shared?.windowDockContainingPanel(terminalSurface.id) else {
                return true
            }
            return dock.focusedPanelId == terminalSurface.id
        }
    }
}
