import Foundation

extension DockSplitStore {
    /// Clears the restore observation window when the resumed command returns to a shell prompt.
    func clearRestoredProcessDetectionObservationIfCommandCompleted(
        panelId: UUID,
        previousState: PanelShellActivityState,
        state: PanelShellActivityState
    ) {
        guard previousState == .commandRunning, state == .promptIdle,
              var restoredBinding = surfaceResumeBindingsByPanelId[panelId] else {
            return
        }
        restoredBinding.clearRestoredProcessDetectionObservation()
        surfaceResumeBindingsByPanelId[panelId] = restoredBinding
    }
}
