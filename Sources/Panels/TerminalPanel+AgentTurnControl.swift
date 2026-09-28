import CmuxMobileHost
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

    /// Sends the agent's interrupt keys, then journals the interrupt so the
    /// pane leaves `running`: agents run no Stop hook when interrupted.
    func interruptAgentTurn(_ target: AgentTurnInterruptTarget) {
        guard AgentTurnInterruptTarget.resolve(statusKeyedStates: containerAgentLifecycleStates) == target else {
            refreshAgentTurnControl()
            return
        }
        for key in target.interruptKeys {
            _ = sendNamedKeyResult(key.rawValue)
        }
        let entries = AgentChatHookSessionStore().entries(agentSource: target.hookSource)
        guard let draft = target.interruptDraft(
            surfaceID: id,
            fallbackWorkspaceID: workspaceId,
            entries: entries
        ) else { return }
        AgentJournalLifecycleCenter.shared.enqueueAppend(draft)
    }

    /// Per-agent lifecycle for this pane from whichever container owns it.
    private var containerAgentLifecycleStates: [String: AgentHibernationLifecycleState] {
        if let dock = DockSplitStore.liveStore(containingPanel: id) {
            return dock.agentRuntimeByPanelId[id]?.agentLifecycleStates ?? [:]
        }
        return surface.owningWorkspace()?.agentLifecycleStatesByPanelId[id] ?? [:]
    }
}
