import CmuxAgentChat
import CmuxUpdater
import CmuxWorkspaces
import Foundation

/// One terminal panel's foreground shell state, for panels no agent session owns.
struct UpdateRelaunchShellPanel: Sendable, Equatable {
    var panelId: UUID
    var shellActivity: PanelShellActivityState?
    /// Remote panels keep running on their host across the relaunch.
    var isRemote: Bool
}

extension AppDelegate {
    /// Maps the shared agent classifier's snapshots to what an update relaunch would interrupt.
    ///
    /// - An agent that survives the relaunch (a `cmux ssh` or cloud pane) is safe: its process
    ///   keeps running on the remote host and the pane re-attaches.
    /// - Any other agent takes the classifier's resume safety: only a running command, an open
    ///   question or permission, or a draft is risky. A model request in flight is care.
    /// - A local panel with no live agent running a foreground command counts as a running
    ///   command.
    nonisolated static func updateRelaunchBlockers(
        agents snapshots: [AgentActivitySnapshot],
        workspaceTitles: [UUID: String],
        shellPanels: [UpdateRelaunchShellPanel]
    ) -> UpdateRelaunchBlockers {
        var blockers = UpdateRelaunchBlockers.empty
        var agentPanelIds = Set<UUID>()
        for snapshot in snapshots where snapshot.activity.kind != .ended {
            agentPanelIds.insert(snapshot.panelID)
            let (safety, activity): (UpdateResumeSafety, String) = snapshot.survivesAppRelaunch
                ? (.safe, String(localized: "update.agentActivity.remote", defaultValue: "Keeps running on the remote host"))
                : (updateResumeSafety(snapshot.assessment.safety), updateRelaunchActivityLine(snapshot.activity))
            blockers.agents.append(UpdateRelaunchAgent(
                id: snapshot.panelID.uuidString,
                name: agentDisplayName(forAgentKind: snapshot.agentKind),
                location: workspaceTitles[snapshot.workspaceID] ?? "",
                safety: safety,
                activity: activity
            ))
        }
        blockers.runningCommandCount = shellPanels.filter {
            !$0.isRemote && $0.shellActivity == .commandRunning && !agentPanelIds.contains($0.panelId)
        }.count
        return blockers
    }

    private nonisolated static func updateResumeSafety(_ safety: ResumeSafety) -> UpdateResumeSafety {
        switch safety {
        case .safe: .safe
        case .care: .care
        case .risky: .risky
        }
    }

    /// Longest command shown in the update popover before it is cut with an ellipsis.
    nonisolated static let updateRelaunchCommandLimit = 60

    /// One short line for what an agent is doing: the command it runs, else the tool, else the
    /// kind of activity. A question or permission prompt says so, whatever tool it is about.
    nonisolated static func updateRelaunchActivityLine(_ activity: AgentActivity) -> String {
        switch activity.kind {
        case .question, .permission:
            return activityLabel(activity.kind)
        default:
            break
        }
        if let command = activity.tool?.command.map(oneLine), !command.isEmpty {
            guard command.count > updateRelaunchCommandLimit else { return command }
            return String(command.prefix(updateRelaunchCommandLimit - 1)) + "\u{2026}"
        }
        if let name = activity.tool?.name, !name.isEmpty {
            return name
        }
        return activityLabel(activity.kind)
    }

    private nonisolated static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private nonisolated static func activityLabel(_ kind: AgentActivity.Kind) -> String {
        switch kind {
        case .idle, .ended:
            String(localized: "update.agentActivity.idle", defaultValue: "Idle")
        case .awaitingInput:
            String(localized: "update.agentActivity.awaitingInput", defaultValue: "Waiting for your next message")
        case .question:
            String(localized: "update.agentActivity.needsInput", defaultValue: "Waiting for your answer")
        case .permission:
            String(localized: "update.agentActivity.permission", defaultValue: "Waiting for your permission")
        case .thinking:
            String(localized: "update.agentActivity.thinking", defaultValue: "Thinking")
        case .tool:
            String(localized: "update.agentActivity.tool", defaultValue: "Using a tool")
        case .subagents:
            String(localized: "update.agentActivity.subagents", defaultValue: "Running subagents")
        case .background:
            String(localized: "update.agentActivity.background", defaultValue: "Running background tasks")
        case .unknown:
            String(localized: "update.agentActivity.working", defaultValue: "Working")
        }
    }

    /// A display name for an agent kind such as `claude` or `codex`.
    nonisolated static func agentDisplayName(forAgentKind kind: String) -> String {
        switch kind.lowercased() {
        case "claude", "claude_code": return "Claude Code"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        default: return kind
        }
    }
}

extension DockSplitStore {
    /// Dock panels keep shell state on each terminal panel.
    func updateRelaunchShellPanels(isRemote: Bool) -> [UpdateRelaunchShellPanel] {
        panels.map { panelId, panel in
            UpdateRelaunchShellPanel(
                panelId: panelId,
                shellActivity: (panel as? TerminalPanel)?.shellActivity.state,
                isRemote: isRemote || terminalLinkIsRemoteTerminal(panelId)
            )
        }
    }
}

extension UpdateRelaunchBlockers {
    /// Panels whose agent an update relaunch would cut off mid-task: every agent that is not
    /// ``UpdateResumeSafety/safe``.
    var midTaskPanelIds: Set<UUID> {
        Set(agents.filter { $0.safety != .safe }.compactMap { UUID(uuidString: $0.id) })
    }
}

/// "Continue where you left off" for agents an update relaunch cut off mid-task.
///
/// The relaunch saves mark those panels (`SessionTerminalPanelSnapshot.resumeWithContinuation`).
/// When the relaunched app resumes one of them, its restore record carries ``prompt`` so the agent
/// picks its turn back up, once.
@MainActor
final class UpdateRelaunchContinuationNudges {
    static let shared = UpdateRelaunchContinuationNudges()

    /// Sent to the agent, not shown to the user, so it is not localized.
    static let prompt = "cmux restarted to install an update while you were working. Continue where you left off."

    /// Panels the session saves mark. Set only once the update relaunch is under way, and kept for
    /// the terminate-path save that follows it.
    var midTaskPanelIds: Set<UUID> = []

    /// How long after the relaunch restore a nudge stays usable. The restore types the resume
    /// right away; a resume that never got through (the user interrupted it, or the session was
    /// gone) must not greet a manual resume hours later.
    static let lifetime: TimeInterval = 600

    /// Restored panels whose next agent resume carries ``prompt``, with the uptime they were
    /// restored at.
    private(set) var pendingPanels: [UUID: TimeInterval] = [:]

    /// Whether a session save should mark `panelId`.
    func marksPanel(_ panelId: UUID) -> Bool? {
        midTaskPanelIds.contains(panelId) ? true : nil
    }

    /// Records a restored panel that auto-resumes its agent from a marked snapshot.
    func registerRestoredPanel(
        _ panelId: UUID,
        snapshot: SessionTerminalPanelSnapshot?,
        resumesAgent: Bool,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard resumesAgent, snapshot?.resumeWithContinuation == true else { return }
        pendingPanels[panelId] = now
    }

    /// The prompt for `panelId`'s next resume, if it has a nudge that has not expired.
    func prompt(forPanel panelId: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String? {
        guard let restoredAt = pendingPanels[panelId] else { return nil }
        guard now - restoredAt <= Self.lifetime else {
            pendingPanels[panelId] = nil
            return nil
        }
        return Self.prompt
    }

    /// Ends the nudge once a resume of `panelId` is admitted.
    func consume(panelId: UUID) {
        pendingPanels[panelId] = nil
    }
}
