import CmuxTerminal
import Foundation

extension Workspace {
    /// Holds native startup for structured Vault restores until their owning
    /// topology has committed panel-scoped responder state.
    nonisolated static func terminalRuntimeSpawnPolicy(
        requestedPolicy: TerminalSurfaceRuntimeSpawnPolicy,
        startupRestoreAgent: SessionRestorableAgentSnapshot?
    ) -> TerminalSurfaceRuntimeSpawnPolicy {
        startupRestoreAgent == nil
            ? requestedPolicy
            : .heldForStartupRestoreAdmission
    }

    /// Commits one terminal's restore lifecycle and chat-session binding, then
    /// explicitly admits native runtime startup.
    ///
    /// Creation paths call this only after their topology mutation succeeds, so
    /// failed tab and split insertions leave neither responder state nor a chat
    /// binding behind.
    func commitTerminalStartupRestore(
        panel: TerminalPanel,
        snapshot: SessionRestorableAgentSnapshot,
        hasQueuedStartupInput: Bool
    ) {
        seedSessionRestoredAgentState(
            panelId: panel.id,
            restorableAgent: snapshot,
            willRunStartupCommand: false,
            willRunStartupInput: hasQueuedStartupInput,
            resumeSessionWorkingDirectory: snapshot.workingDirectory
        )
        AgentChatTranscriptService.recordResumeIntent(
            sessionID: snapshot.sessionId,
            source: snapshot.kind.rawValue,
            surfaceID: panel.id.uuidString,
            workspaceID: id.uuidString,
            workingDirectory: snapshot.workingDirectory
        )
        panel.surface.admitStartupRestoreRuntime()
    }
}
