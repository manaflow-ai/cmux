import Foundation

extension DockSplitStore {
    /// Delivers the retained startup input once, only to the still-idle live runtime.
    func resendRestoredStartupInputIfStillIdle(panelId: UUID) {
        guard let terminal = panels[panelId] as? TerminalPanel,
              let input = restoredAgentLifecycle.takeStartupInputForResend(
                  panelId: panelId,
                  shellState: terminal.shellActivity.state
              ) else {
            return
        }
        // The idle prompt came from a live runtime; never queue the selector
        // for some future shell of this pane.
        guard terminal.surface.surface != nil else { return }
        let result = terminal.sendInputResult(input)
#if DEBUG
        cmuxDebugLog(
            "session.restore.startupInput.resend dock=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) result=\(result) bytes=\(input.utf8.count)"
        )
#endif
    }
}
