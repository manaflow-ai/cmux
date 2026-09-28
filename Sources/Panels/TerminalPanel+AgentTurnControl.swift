import Foundation

extension TerminalPanel {
    /// Shows the Stop button while a supported agent is running in this pane.
    /// Called whenever the pane's journaled agent lifecycle changes.
    func refreshAgentTurnControl() {
        let view = hostedView.agentTurnControlView
        if view.onInterrupt == nil {
            view.onInterrupt = { [weak self] target in
                self?.interruptAgentTurn(target)
            }
        }
        view.setRunningTarget(AgentTurnInterruptTarget.resolve(statusKeyedStates: containerAgentLifecycleStates))
    }

    /// Sends the agent's interrupt keys, then, for Claude Code, journals the
    /// interrupt so the pane leaves `running`: Claude runs no Stop hook when
    /// interrupted.
    func interruptAgentTurn(_ target: AgentTurnInterruptTarget) {
        guard AgentTurnInterruptTarget.resolve(statusKeyedStates: containerAgentLifecycleStates) == target else {
            refreshAgentTurnControl()
            return
        }
        for key in target.interruptKeys {
            _ = sendNamedKeyResult(key.rawValue)
        }
        guard target.settlesTurnInJournal else { return }
        AgentJournalLifecycleCenter.shared.recordUserInterrupt(
            surfaceId: id,
            workspaceId: workspaceId,
            agentKey: target.statusKey,
            source: target.hookSource
        )
    }

    /// Per-agent lifecycle for this pane from whichever container owns it.
    var containerAgentLifecycleStates: [String: AgentHibernationLifecycleState] {
        if let dock = DockSplitStore.liveStore(containingPanel: id) {
            return dock.agentRuntimeByPanelId[id]?.agentLifecycleStates ?? [:]
        }
        return surface.owningWorkspace()?.agentLifecycleStatesByPanelId[id] ?? [:]
    }
}
