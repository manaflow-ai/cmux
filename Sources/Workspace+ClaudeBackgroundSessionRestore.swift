import CMUXAgentLaunch
import CmuxTerminal
import CmuxWorkspaces
import Foundation

/// How one restored terminal relates to a live Claude background session.
enum ClaudeBackgroundAttachRestore: Sendable {
    /// This pane reattaches the session.
    case attach(plan: ClaudeBackgroundAttachPlan, startupInput: String)
    /// Another pane in this restore attaches the session; this one must not resume it.
    case attachedElsewhere(ClaudeBackgroundSessionRegistration)

    var attach: (plan: ClaudeBackgroundAttachPlan, startupInput: String)? {
        if case .attach(let plan, let startupInput) = self { return (plan, startupInput) }
        return nil
    }

    var registration: ClaudeBackgroundSessionRegistration {
        switch self {
        case .attach(let plan, _): return plan.registration
        case .attachedElsewhere(let registration): return registration
        }
    }
}

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

    /// Plans background-session reattachment for every terminal in one
    /// workspace restore pass.
    ///
    /// - A pane qualifies when it recorded a `claude attach` viewer, or when
    ///   its hook-reported Claude session was running at quit. A pane that only
    ///   spawned a background session and went back to shell work is left alone.
    /// - Claude's registry is scanned at most once per config directory.
    /// - One pane attaches per session, preferring the viewer pane. Other panes
    ///   on the same live session keep no startup work; they must not resume it.
    ///
    /// Interactive sessions and sessions the daemon no longer hosts get no
    /// entry, so those panels keep their existing restore.
    nonisolated static func claudeBackgroundAttachRestores(
        panels: [SessionPanelSnapshot],
        skipsRemoteTerminals: Bool,
        attach: ClaudeBackgroundSessionAttach = ClaudeBackgroundSessionAttach(
            lookup: ClaudeBackgroundSessionAttach.memoizedRegistryLookup()
        )
    ) -> [UUID: ClaudeBackgroundAttachRestore] {
        var candidates: [(panelID: UUID, hasViewer: Bool, plan: ClaudeBackgroundAttachPlan)] = []
        for panel in panels where panel.type == .terminal {
            guard let terminal = panel.terminal,
                  terminal.isRemoteTerminal != true,
                  !(skipsRemoteTerminals && terminal.isRemoteTerminal != false),
                  terminal.tmuxStartCommand == nil,
                  terminal.hibernation == nil else {
                continue
            }
            let restorableAgent = restorableAgentForSessionRestore(
                terminal.agent,
                resumeBinding: terminal.resumeBinding
            )
            let resumeBinding = resumeBindingForSessionRestore(
                terminal.resumeBinding,
                restorableAgent: restorableAgent
            )
            let viewer = terminal.claudeBackgroundViewer
            let hookSession = viewer != nil || terminal.wasAgentRunning != false
                ? claudeBackgroundHookSession(restorableAgent: restorableAgent, resumeBinding: resumeBinding)
                : nil
            guard viewer != nil || hookSession != nil,
                  let plan = attach.plan(viewer: viewer, hookSession: hookSession) else {
                continue
            }
            candidates.append((panel.id, viewer != nil, plan))
        }
        var winnerBySession: [String: UUID] = [:]
        for candidate in candidates {
            let key = candidate.plan.registration.sessionID.lowercased()
            if winnerBySession[key] == nil { winnerBySession[key] = candidate.panelID }
        }
        for candidate in candidates where candidate.hasViewer {
            let key = candidate.plan.registration.sessionID.lowercased()
            let current = winnerBySession[key]
            if current.flatMap({ id in candidates.first { $0.panelID == id }?.hasViewer }) != true {
                winnerBySession[key] = candidate.panelID
            }
        }
        var restores: [UUID: ClaudeBackgroundAttachRestore] = [:]
        for candidate in candidates {
            let key = candidate.plan.registration.sessionID.lowercased()
            restores[candidate.panelID] = winnerBySession[key] == candidate.panelID
                ? .attach(
                    plan: candidate.plan,
                    startupInput: AgentRestoreAttachCommand.claudeBackgroundStartupInput(candidate.plan)
                )
                : .attachedElsewhere(candidate.plan.registration)
        }
        return restores
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
