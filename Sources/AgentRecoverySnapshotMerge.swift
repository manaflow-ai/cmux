import CMUXAgentLaunch
import Foundation

/// Folds agent sessions that were running when cmux died back into the panels
/// of the snapshot that crashed run left behind.
///
/// The snapshot is an 8 s autosave, so an agent started (or replaced) shortly
/// before a crash, force quit or power loss is missing from it. The journal
/// and hook store already know the session and its panel, so writing it into
/// the panel before restore lets normal startup restore resume it in place,
/// with the same admission, launch claim and start-on-visit pacing as any
/// restored agent. Sessions with no surviving panel stay with
/// ``AgentSessionRecovery``, which reopens them in new workspaces and skips
/// the ones placed here because their panels now carry them.
enum AgentRecoverySnapshotMerge {
    static func merging(
        _ candidates: [AgentRecoveryCandidate],
        into snapshot: AppSessionSnapshot
    ) -> AppSessionSnapshot {
        guard !candidates.isEmpty else { return snapshot }
        let placement = AgentRecoveryPanePlacement(
            candidates: candidates,
            panes: panes(in: snapshot),
            snapshotCreatedAt: Date(timeIntervalSince1970: snapshot.createdAt)
        )
        guard !placement.assignments.isEmpty else { return snapshot }
        var merged = snapshot
        for windowIndex in merged.windows.indices {
            for workspaceIndex in merged.windows[windowIndex].tabManager.workspaces.indices {
                let workspace = merged.windows[windowIndex].tabManager.workspaces[workspaceIndex]
                guard let workspaceId = workspace.workspaceId else { continue }
                apply(placement, workspaceId: workspaceId,
                      to: &merged.windows[windowIndex].tabManager.workspaces[workspaceIndex].panels)
                if merged.windows[windowIndex].tabManager.workspaces[workspaceIndex].dock != nil {
                    apply(placement, workspaceId: workspaceId,
                          to: &merged.windows[windowIndex].tabManager.workspaces[workspaceIndex].dock!.panels)
                }
            }
        }
        return merged
    }

    static func panes(in snapshot: AppSessionSnapshot) -> [AgentRecoveryPane] {
        var panes: [AgentRecoveryPane] = []
        for window in snapshot.windows {
            for workspace in window.tabManager.workspaces {
                guard let workspaceId = workspace.workspaceId else { continue }
                let isLocalWorkspace = workspace.remote == nil && workspace.cloudVM == nil
                for panel in workspace.panels + (workspace.dock?.panels ?? []) {
                    guard let terminal = panel.terminal else { continue }
                    panes.append(AgentRecoveryPane(
                        workspaceId: workspaceId,
                        panelId: panel.id,
                        sessionId: terminal.agent?.sessionId,
                        canHostAgent: isLocalWorkspace && canHostAgent(terminal)
                    ))
                }
            }
        }
        return panes
    }

    /// Only a plain local shell resumes through the restore verb; tmux,
    /// remote PTY and remote terminals own their own startup.
    private static func canHostAgent(_ terminal: SessionTerminalPanelSnapshot) -> Bool {
        terminal.tmuxStartCommand == nil
            && terminal.isRemoteTerminal != true
            && terminal.remotePTYSessionID == nil
    }

    private static func apply(
        _ placement: AgentRecoveryPanePlacement,
        workspaceId: UUID,
        to panels: inout [SessionPanelSnapshot]
    ) {
        for index in panels.indices {
            let key = AgentRecoveryPanePlacement.PanelKey(workspaceId: workspaceId, panelId: panels[index].id)
            guard panels[index].terminal != nil,
                  let candidate = placement.assignments[key],
                  let agent = AgentSessionRecovery.restorableAgent(for: candidate) else { continue }
            panels[index].terminal?.agent = agent
            panels[index].terminal?.wasAgentRunning = true
            // Bindings and hibernation describe the session the snapshot saw,
            // which the newer session replaced in this panel.
            panels[index].terminal?.resumeBinding = nil
            panels[index].terminal?.managedAgentResumeBinding = nil
            panels[index].terminal?.hibernation = nil
        }
    }
}
