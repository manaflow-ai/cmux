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
