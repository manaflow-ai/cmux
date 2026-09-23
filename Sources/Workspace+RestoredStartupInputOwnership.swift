import Foundation

extension Workspace {
    /// Prompt delivery belongs to the terminal and survives container transfers.
    func scheduleRestoredStartupInputResend(panelId: UUID) {
        resendRestoredStartupInputIfStillIdle(panelId: panelId)
    }

    func resendRestoredStartupInputIfStillIdle(panelId: UUID) {
        guard !isRetiredFromOwningTabManager,
              panelShellActivityStates[panelId] == .promptIdle,
              let terminal = panels[panelId] as? TerminalPanel else { return }
        terminal.surface.shellDidBecomeReadyForStartupInput()
    }
}
