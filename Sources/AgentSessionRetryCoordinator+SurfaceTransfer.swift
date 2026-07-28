import CmuxWorkspaces
import Foundation

extension AgentSessionRetryCoordinator {
    /// Captures proof that a transferred pane's managed checkpoint owns its command.
    func transferredCompletedAttempts(
        panelId: UUID,
        shellActivityState: PanelShellActivityState?,
        binding: SurfaceResumeBindingSnapshot?
    ) -> Int? {
        guard settings.isEnabled,
              shellActivityState == .commandRunning,
              let binding,
              let commandGeneration = commandGenerationsByPanelId[panelId],
              let ownedRun = managedRunsByPanelId[panelId],
              ownedRun.commandGeneration == commandGeneration,
              ownedRun.binding.isSameManagedSession(as: binding) else {
            return nil
        }
        return statesByPanelId[panelId]?.completedAttempts ?? 0
    }

    /// Reconstructs transferred command ownership; missing or stale facts fail closed.
    func seedTransferredManagedRun(
        panelId: UUID,
        shellActivityState: PanelShellActivityState?,
        binding: SurfaceResumeBindingSnapshot?,
        completedAttempts: Int?
    ) {
        guard settings.isEnabled,
              shellActivityState == .commandRunning,
              let binding,
              binding.isAgentHookBinding,
              binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let completedAttempts,
              completedAttempts >= 0,
              completedAttempts <= policy.maximumAttempts else {
            cancel(panelId: panelId)
            return
        }

        let commandGeneration = (commandGenerationsByPanelId[panelId] ?? 0) &+ 1
        commandGenerationsByPanelId[panelId] = commandGeneration
        managedRunsByPanelId[panelId] = ManagedRunOwnership(
            binding: binding,
            commandGeneration: commandGeneration
        )
        if completedAttempts > 0 {
            statesByPanelId[panelId] = RetryState(
                completedAttempts: completedAttempts,
                binding: binding,
                commandGeneration: commandGeneration,
                phase: .launching(
                    attempt: completedAttempts,
                    maximumAttempts: policy.maximumAttempts
                ),
                timer: nil
            )
        }
    }
}
