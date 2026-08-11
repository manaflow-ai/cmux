import CmuxTerminal
import Foundation

extension Workspace {
    /// Defers native terminal startup until the owning topology can resolve the
    /// structured restore selector through its panel-scoped lifecycle state.
    ///
    /// The restore scheduler starts on a later main-actor turn. That gives a
    /// successful workspace, tab, or split insertion time to commit the panel
    /// snapshot before the queued `cmux restore` input can reach the socket.
    static func terminalRuntimeSpawnPolicy(
        requestedPolicy: TerminalSurfaceRuntimeSpawnPolicy,
        startupRestoreAgent: SessionRestorableAgentSnapshot?
    ) -> TerminalSurfaceRuntimeSpawnPolicy {
        startupRestoreAgent == nil ? requestedPolicy : .pacedSessionRestore
    }

    /// Commits one admitted terminal's restore lifecycle and chat-session
    /// binding before its paced native runtime is allowed to start.
    ///
    /// Creation paths call this only after their topology mutation succeeds, so
    /// failed tab and split insertions leave neither responder state nor a chat
    /// binding behind.
    func commitTerminalStartupRestore(
        panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        hasQueuedStartupInput: Bool
    ) {
        seedSessionRestoredAgentState(
            panelId: panelId,
            restorableAgent: snapshot,
            willRunStartupCommand: false,
            willRunStartupInput: hasQueuedStartupInput,
            resumeSessionWorkingDirectory: snapshot.workingDirectory
        )
        AgentChatTranscriptService.recordResumeIntent(
            sessionID: snapshot.sessionId,
            source: snapshot.kind.rawValue,
            surfaceID: panelId.uuidString,
            workspaceID: id.uuidString,
            workingDirectory: snapshot.workingDirectory
        )
    }
}
