import CmuxTerminal
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
        interruptAgentTurn(
            target,
            sendNamedKey: { sendNamedKeyResult($0) },
            recordUserInterrupt: {
                AgentJournalLifecycleCenter.shared.recordUserInterrupt(
                    surfaceId: id,
                    workspaceId: workspaceId,
                    agentKey: target.statusKey,
                    source: target.hookSource
                )
            }
        )
    }

    /// Injectable form used to prove failed terminal input never settles the
    /// journaled turn.
    func interruptAgentTurn(
        _ target: AgentTurnInterruptTarget,
        sendNamedKey: (String) -> TerminalSurface.NamedKeySendResult,
        recordUserInterrupt: () -> Void
    ) {
        guard AgentTurnInterruptTarget.resolve(statusKeyedStates: containerAgentLifecycleStates) == target else {
            refreshAgentTurnControl()
            return
        }
        for key in target.interruptKeys {
            guard sendNamedKey(key.rawValue).accepted else { return }
        }
        guard target.settlesTurnInJournal else { return }
        recordUserInterrupt()
    }

    /// Per-agent lifecycle for this pane from whichever container owns it.
    private var containerAgentLifecycleStates: [String: AgentHibernationLifecycleState] {
        if let dock = DockSplitStore.liveStore(containingPanel: id) {
            return dock.agentRuntimeByPanelId[id]?.agentLifecycleStates ?? [:]
        }
        return surface.owningWorkspace()?.agentLifecycleStatesByPanelId[id] ?? [:]
    }
}
