import CmuxUpdater
import CmuxWorkspaces
import Foundation

/// One terminal panel as an update relaunch would find it.
struct UpdateRelaunchPanelActivity: Sendable {
    var panelId: UUID
    /// Where the panel lives, such as its workspace title.
    var location: String
    var agentLifecycles: [String: AgentHibernationLifecycleState]
    var shellActivity: PanelShellActivityState?
    var isRemote: Bool
}

extension AppDelegate {
    /// Classifies what an update relaunch would interrupt, per agent session.
    ///
    /// This reads the lifecycle state agent hooks report, which cannot tell a model request from
    /// a foreground build, so a mid-turn local agent counts as risky until the shared per-agent
    /// classifier (hooks plus the pane's process tree) replaces it:
    /// - A remote agent is safe: `cmux ssh` panes run on a daemon on the remote host, so the
    ///   agent keeps running across the relaunch and the pane re-attaches.
    /// - A local agent waiting on the user (a permission prompt or a question) is risky, and so
    ///   is a local agent that is mid-turn.
    /// - A local agent at its prompt is safe.
    /// - A local panel with no agent running a foreground command counts as a running command.
    ///
    /// Manual `cmux workspace loading` keys are not agents and are ignored.
    nonisolated static func updateRelaunchBlockers(
        panels: [UpdateRelaunchPanelActivity]
    ) -> UpdateRelaunchBlockers {
        var blockers = UpdateRelaunchBlockers.empty
        for panel in panels {
            let agentStates = panel.agentLifecycles
                .filter { !AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
            guard let agentKey = agentStates.keys.sorted().first(where: { !isAttentionKey($0) }) ?? agentStates.keys.sorted().first else {
                if !panel.isRemote, panel.shellActivity == .commandRunning {
                    blockers.runningCommandCount += 1
                }
                continue
            }
            let states = Set(agentStates.values)
            let (safety, activity): (UpdateResumeSafety, String)
            if panel.isRemote {
                safety = .safe
                activity = String(localized: "update.agentActivity.remote", defaultValue: "Keeps running on the remote host")
            } else if states.contains(.needsInput) {
                safety = .risky
                activity = String(localized: "update.agentActivity.needsInput", defaultValue: "Waiting for your answer")
            } else if states.contains(.running) {
                safety = .risky
                activity = String(localized: "update.agentActivity.working", defaultValue: "Working")
            } else {
                safety = .safe
                activity = String(localized: "update.agentActivity.idle", defaultValue: "Idle")
            }
            blockers.agents.append(UpdateRelaunchAgent(
                id: panel.panelId.uuidString,
                name: agentDisplayName(forLifecycleKey: agentKey),
                location: panel.location,
                safety: safety,
                activity: activity
            ))
        }
        return blockers
    }

    private nonisolated static func isAttentionKey(_ key: String) -> Bool {
        key.hasPrefix("cmux.feed.attention:")
    }

    /// A display name for an agent lifecycle key such as `claude_code` or `codex.<session>`.
    nonisolated static func agentDisplayName(forLifecycleKey key: String) -> String {
        let base = key
            .replacingOccurrences(of: "cmux.feed.attention:", with: "")
            .split(separator: ".").first.map(String.init)?
            .lowercased() ?? key
        switch base {
        case "claude", "claude_code": return "Claude Code"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        default: return base.isEmpty ? key : base
        }
    }
}

extension DockSplitStore {
    /// Dock panels keep agent lifecycle in their runtime map and shell state on the panel.
    func updateRelaunchPanelActivity(location: String, isRemote: Bool) -> [UpdateRelaunchPanelActivity] {
        panels.map { panelId, panel in
            UpdateRelaunchPanelActivity(
                panelId: panelId,
                location: location,
                agentLifecycles: agentRuntimeByPanelId[panelId]?.agentLifecycleStates ?? [:],
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
    private var midTaskPanelIds: Set<UUID> = []
    private var midTaskPanelIdsExpiresAt: TimeInterval = 0

    func arm(panelIds: Set<UUID>, expiresAtUptime: TimeInterval) {
        midTaskPanelIds = panelIds
        midTaskPanelIdsExpiresAt = expiresAtUptime
    }

    /// How long after the relaunch restore a nudge stays usable. The restore types the resume
    /// right away; a resume that never got through (the user interrupted it, or the session was
    /// gone) must not greet a manual resume hours later.
    static let lifetime: TimeInterval = 600

    /// Restored panels whose next agent resume carries ``prompt``, with the uptime they were
    /// restored at.
    private struct PendingPanel {
        let restoredAt: TimeInterval
        let checkpointID: String?
    }

    private var pendingPanels: [UUID: PendingPanel] = [:]

    /// Whether a session save should mark `panelId`.
    func marksPanel(_ panelId: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool? {
        guard now <= midTaskPanelIdsExpiresAt else { return nil }
        return midTaskPanelIds.contains(panelId) ? true : nil
    }

    /// Records a restored panel that auto-resumes its agent from a marked snapshot.
    func registerRestoredPanel(
        _ panelId: UUID,
        snapshot: SessionTerminalPanelSnapshot?,
        resumesAgent: Bool,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard resumesAgent, snapshot?.resumeWithContinuation == true else {
            pendingPanels[panelId] = nil
            return
        }
        let checkpointID = snapshot?.agent?.sessionId
            ?? snapshot?.managedAgentResumeBinding?.checkpointId
            ?? snapshot?.resumeBinding?.checkpointId
        pendingPanels[panelId] = PendingPanel(restoredAt: now, checkpointID: checkpointID)
    }

    /// The prompt for `panelId`'s next resume, if it has a nudge that has not expired.
    func prompt(
        forPanel panelId: UUID,
        checkpointID: String?,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> String? {
        guard let pending = pendingPanels[panelId] else { return nil }
        guard now - pending.restoredAt <= Self.lifetime else {
            pendingPanels[panelId] = nil
            return nil
        }
        guard pending.checkpointID == checkpointID else { return nil }
        return Self.prompt
    }

    /// Ends the nudge once a resume of `panelId` is admitted.
    func consume(panelId: UUID) {
        pendingPanels[panelId] = nil
    }
}
