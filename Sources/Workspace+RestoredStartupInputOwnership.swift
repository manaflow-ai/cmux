import Foundation

extension Workspace {
    /// Grace period between a restored launch's shell settling at an idle prompt
    /// and replaying its startup input.
    static var restoredStartupInputResendGrace: TimeInterval = 2

    /// Replays a retained restore selector once after the shell reports an idle prompt.
    func scheduleRestoredStartupInputResend(panelId: UUID) {
        guard restoredAgentLifecycle.armStartupInputResend(panelId: panelId) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoredStartupInputResendGrace) { [weak self] in
            Task { @MainActor [weak self] in
                self?.resendRestoredStartupInputIfStillIdle(panelId: panelId)
            }
        }
    }

    func resendRestoredStartupInputIfStillIdle(panelId: UUID) {
        let shellState = panelShellActivityStates[panelId] ?? .unknown
        let hasLiveAgent = restoredAgentSnapshotsByPanelId[panelId].map {
            restoredAgentHasLiveProcess($0, panelId: panelId)
        } == true || agentHookBindingHasLiveProcess(panelId: panelId)
        guard !isRetiredFromOwningTabManager,
              let terminal = panels[panelId] as? TerminalPanel,
              let input = restoredAgentLifecycle.takeStartupInputForResend(
                  panelId: panelId,
                  shellState: shellState,
                  hasLiveAgent: hasLiveAgent
              ),
              terminal.surface.surface != nil else { return }
        _ = terminal.sendInputResult(input)
    }
}
