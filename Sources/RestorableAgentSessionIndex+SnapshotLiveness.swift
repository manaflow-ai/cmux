import CmuxFoundation
import CmuxWorkspaces

extension RestorableAgentSessionIndex.Entry {
    /// Resolves a matched hook session's snapshot state. Execution admission
    /// still validates its live owner. A generic shell activity state is not
    /// agent liveness: after relaunch the shell may be running a restore
    /// scaffold, while the agent process and its hook are gone.
    func wasRunningForSnapshot(
        _ agentSnapshot: SessionRestorableAgentSnapshot,
        binding: SurfaceResumeBindingSnapshot,
        confirmedRuntimeProcessIdentities: Set<AgentPIDProcessIdentity>,
        currentProcessIdentity: (Int) -> AgentPIDProcessIdentity?,
        processPresence: (Int) -> PIDPresence
    ) -> Bool {
        if CodexTurnRestoreIntentPolicy.shouldPreserveAfterOwnerExit(
            snapshot: agentSnapshot,
            binding: binding,
            processLiveness: processLiveness
        ) {
            return true
        }
        return processLiveness.wasRunning(
            // Only an agent-owned process identity or hook observation may
            // establish Running after restore. Shell activity is deliberately
            // ignored here so a stale snapshot cannot repaint the badge.
            fallingBackTo: nil,
            recordedProcessIdentities: agentProcessIdentities,
            confirmedRuntimeProcessIdentities: confirmedRuntimeProcessIdentities,
            currentProcessIdentity: currentProcessIdentity,
            processPresence: processPresence
        ) ?? false
    }
}
