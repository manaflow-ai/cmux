import CmuxWorkspaces

extension TerminalPanel {
    func updateShellActivityState(_ state: PanelShellActivityState) {
        // A returning prompt ends a CLI-reported recovery. A pending container
        // admission owns its own presentation and clears it when it resolves.
        if state == .promptIdle, shellActivity.state == .commandRunning,
           !surface.isAwaitingStartupRestoreAdmission {
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
