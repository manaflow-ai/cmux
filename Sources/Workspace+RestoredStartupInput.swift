import Foundation

extension Workspace {
    /// Delivers the retained startup input once, only to the still-owned idle runtime.
    func resendRestoredStartupInputIfStillIdle(panelId: UUID) {
        let shellState = panelShellActivityStates[panelId] ?? .unknown
        guard !isRetiredFromOwningTabManager,
              let terminal = panels[panelId] as? TerminalPanel,
              let input = restoredAgentLifecycle.takeStartupInputForResend(panelId: panelId, shellState: shellState),
              terminal.surface.surface != nil else { return }
        _ = terminal.sendInputResult(input)
    }
}
