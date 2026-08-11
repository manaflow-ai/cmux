import CmuxAgentChat
import CmuxTerminal
import Foundation

extension Workspace {
    /// Adds topology admission to any structured restore without changing its
    /// immediate-versus-paced spawn timing.
    nonisolated static func terminalRuntimeSpawnPolicy(
        requestedPolicy: TerminalSurfaceRuntimeSpawnPolicy,
        requiresStartupRestoreAdmission: Bool
    ) -> TerminalSurfaceRuntimeSpawnPolicy {
        requiresStartupRestoreAdmission
            ? requestedPolicy.requiringStartupRestoreAdmission()
            : requestedPolicy
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
        agentChatResumeIntentRecorder.record(AgentChatResumeIntent(
            sessionID: snapshot.sessionId,
            source: snapshot.kind.rawValue,
            surfaceID: panel.id.uuidString,
            workspaceID: id.uuidString,
            workingDirectory: snapshot.workingDirectory
        ))
        panel.surface.admitStartupRestoreRuntime()
    }

    /// Releases every structured terminal restored by this workspace.
    ///
    /// Full-window restoration calls this only after `TabManager.tabs` is
    /// authoritative. Direct workspace and closed-item restores call it once
    /// their own panel topology is complete.
    func admitSessionRestoredTerminalRuntimes() {
        for terminalPanel in panels.values.compactMap({ $0 as? TerminalPanel }) {
            terminalPanel.surface.admitStartupRestoreRuntime()
        }
    }
}
