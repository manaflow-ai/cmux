import Foundation

extension DockSplitStore {
    /// Dock transfers retain the same terminal-owned, one-shot readiness gate.
    func scheduleRestoredStartupInputResend(panelId: UUID) {
        guard let terminal = panels[panelId] as? TerminalPanel,
              terminal.shellActivity.state == .promptIdle else { return }
        terminal.surface.shellDidBecomeReadyForStartupInput()
    }
}
