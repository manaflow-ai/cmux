import CMUXAgentLaunch
import CmuxTerminal
import CmuxWorkspaces
import Foundation

/// One autosave observation of a pane's foreground process.
struct ClaudeBackgroundViewerObservation: Sendable {
    let processID: Int
    let viewer: ClaudeBackgroundSessionViewer?
}

/// Restores panes that were viewing a Claude Code background session.
///
/// Claude's daemon (`claude bg-pty-host` / `claude bg-spare`) owns a
/// background session; a cmux pane only runs a `claude attach` viewer. On
/// relaunch the session is still live in the daemon, so the pane must
/// reattach. `claude --resume` would contend with the daemon as a second
/// writer, and the manual hook binding alone left a bare shell.
extension Workspace {
    /// Records the `claude attach <id|name>` viewer running in a pane, if any.
    ///
    /// The argv read happens once per foreground process; later autosaves
    /// reuse the observation while the same PID stays in the foreground.
    func claudeBackgroundViewerForSnapshot(
        panelId: UUID,
        terminal: TerminalPanel,
        processArguments: (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        }
    ) -> ClaudeBackgroundSessionViewer? {
        guard !isRemoteTerminalSurface(panelId),
              panelShellActivityStates[panelId] != .promptIdle,
              let processID = terminal.surface.foregroundProcessID() else {
            claudeBackgroundViewerObservationsByPanelId.removeValue(forKey: panelId)
            return nil
        }
        if let observation = claudeBackgroundViewerObservationsByPanelId[panelId],
           observation.processID == processID {
            return observation.viewer
        }
        let viewer = processArguments(processID).flatMap {
            ClaudeBackgroundSessionAttach.viewer(
                arguments: $0.arguments,
                environment: $0.environment
            )
        }
        claudeBackgroundViewerObservationsByPanelId[panelId] = ClaudeBackgroundViewerObservation(
            processID: processID,
            viewer: viewer
        )
        return viewer
    }

    /// Drops viewer observations for panels that no longer exist.
    func pruneClaudeBackgroundViewerObservations() {
        guard !claudeBackgroundViewerObservationsByPanelId.isEmpty else { return }
        claudeBackgroundViewerObservationsByPanelId = claudeBackgroundViewerObservationsByPanelId
            .filter { panels[$0.key] != nil }
    }

    /// Plans the attach-only startup input for a restored local terminal whose
    /// Claude session is still hosted by Claude's background daemon.
    ///
    /// Returns `nil` for interactive sessions and when the daemon no longer
    /// lists the session, so those panels keep their existing restore.
    nonisolated static func claudeBackgroundAttachRestore(
        terminal: SessionTerminalPanelSnapshot?,
        restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        attach: ClaudeBackgroundSessionAttach = ClaudeBackgroundSessionAttach()
    ) -> (plan: ClaudeBackgroundAttachPlan, startupInput: String)? {
        let viewer = terminal?.claudeBackgroundViewer
        let hookSession = claudeBackgroundHookSession(
            restorableAgent: restorableAgent,
            resumeBinding: resumeBinding
        )
        guard viewer != nil || hookSession != nil,
              let plan = attach.plan(viewer: viewer, hookSession: hookSession) else {
            return nil
        }
        return (plan, AgentRestoreAttachCommand.claudeBackgroundStartupInput(plan))
    }

    private nonisolated static func claudeBackgroundHookSession(
        restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?
    ) -> ClaudeBackgroundSessionAttach.HookSession? {
        if let resumeBinding,
           resumeBinding.isAgentHookBinding,
           resumeBinding.launchFlavor == .local,
           resumeBinding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "claude",
           let sessionID = resumeBinding.checkpointId {
            let launchCommand = resumeBinding.launchCommand
            let environment = (launchCommand?.environment ?? [:])
                .merging(resumeBinding.environment ?? [:]) { _, binding in binding }
            return ClaudeBackgroundSessionAttach.HookSession(
                sessionID: sessionID,
                launchArguments: launchCommand?.arguments ?? [],
                launcher: launchCommand?.launcher,
                environment: environment
            )
        }
        guard let restorableAgent, restorableAgent.kind == .claude else { return nil }
        let launchCommand = restorableAgent.launchCommand
        return ClaudeBackgroundSessionAttach.HookSession(
            sessionID: restorableAgent.sessionId,
            launchArguments: launchCommand?.arguments ?? [],
            launcher: launchCommand?.launcher,
            environment: launchCommand?.environment ?? [:]
        )
    }
}
