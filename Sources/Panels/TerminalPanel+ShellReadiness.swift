import CmuxWorkspaces

extension TerminalPanel {
    func updateShellActivityState(_ state: PanelShellActivityState) {
        if state == .promptIdle, shellActivity.state == .commandRunning {
            restoreRecovery.state = nil
        }
        if shellActivity.state != state {
            shellActivity.state = state
        }
        textBoxState.updateShellActivityState(state)
        if state == .promptIdle {
            surface.shellDidBecomeReadyForStartupInput()
        }
    }
}
