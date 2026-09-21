import Foundation

extension DockSplitStore {
    /// Replays a retained restore selector once after the shell reports an idle prompt.
    func scheduleRestoredStartupInputResend(panelId: UUID) {
        guard restoredAgentLifecycle.armStartupInputResend(panelId: panelId) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Workspace.restoredStartupInputResendGrace) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      let terminal = self.panels[panelId] as? TerminalPanel,
                      let input = self.restoredAgentLifecycle.takeStartupInputForResend(
                          panelId: panelId,
                          shellState: terminal.shellActivity.state,
                          hasLiveAgent: self.restoredAgentHasLiveProcess(
                              panelId: panelId,
                              restoredAgent: self.restoredAgentLifecycle.snapshotsByPanelId[panelId]
                          )
                      ),
                      terminal.surface.surface != nil else { return }
                _ = terminal.sendInputResult(input)
                if var binding = self.surfaceResumeBindingsByPanelId[panelId] {
                    // A replayed startup selector is the explicit settle signal
                    // for a process-detected restore with no command callback.
                    binding.clearRestoredProcessDetectionObservation()
                    self.surfaceResumeBindingsByPanelId[panelId] = binding
                }
            }
        }
    }
}
