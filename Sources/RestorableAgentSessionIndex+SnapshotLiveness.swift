import CmuxFoundation
import CmuxWorkspaces

extension RestorableAgentSessionIndex.Entry {
    /// Resolves a matched hook session's snapshot state, including unfinished
    /// Codex restore intent. Execution admission still validates its live owner.
    func wasRunningForSnapshot(
        _ agentSnapshot: SessionRestorableAgentSnapshot,
        binding: SurfaceResumeBindingSnapshot,
        fallingBackTo shellActivityState: PanelShellActivityState?,
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
            fallingBackTo: shellActivityState,
            recordedProcessIdentities: agentProcessIdentities,
            confirmedRuntimeProcessIdentities: confirmedRuntimeProcessIdentities,
            currentProcessIdentity: currentProcessIdentity,
            processPresence: processPresence
        ) ?? false
    }
}
