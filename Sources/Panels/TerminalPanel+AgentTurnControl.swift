import Foundation

extension TerminalPanel {
    /// Shows the agent action pill while a supported agent is running in this
    /// pane. Called whenever the pane's journaled agent lifecycle changes.
    func refreshAgentTurnControl() {
        let view = hostedView.agentTurnControlView
        if view.onInterrupt == nil {
            view.onInterrupt = { [weak self] target in
                self?.interruptAgentTurn(target)
            }
            view.onEditQueued = { [weak self] in
                self?.editQueuedPrompts()
            }
            view.onSettingsChange = { [weak self] in
                self?.refreshAgentTurnControl()
            }
        }
        let target = AgentTurnInterruptTarget.resolve(statusKeyedStates: containerAgentLifecycleStates)
        view.setRunningTarget(target)
        watchClaudeQueuedPrompts(target == .claudeCode && view.isPromptEditingEnabled)
    }

    /// Sends Up, which moves Claude's queued prompts back into its input.
    func editQueuedPrompts() {
        guard AgentTurnInterruptTarget.resolve(statusKeyedStates: containerAgentLifecycleStates) == .claudeCode else {
            refreshAgentTurnControl()
            return
        }
        _ = sendNamedKeyResult(TextBoxTerminalKey.arrowUp.rawValue)
    }

    private func watchClaudeQueuedPrompts(_ watch: Bool) {
        if watch {
            guard claudeQueuedPromptMonitor == nil else { return }
            let token = UUID()
            let monitor = ClaudeQueuedPromptMonitor(surfaceID: id) { [weak self] count in
                guard let self, self.claudeQueuedPromptMonitor?.token == token else { return }
                self.hostedView.agentTurnControlView.setQueuedPromptCount(count)
            }
            claudeQueuedPromptMonitor = (token, monitor)
            Task { await monitor.start() }
        } else if let monitor = claudeQueuedPromptMonitor?.monitor {
            claudeQueuedPromptMonitor = nil
            hostedView.agentTurnControlView.setQueuedPromptCount(0)
            Task { await monitor.stop() }
        }
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
    private var containerAgentLifecycleStates: [String: AgentHibernationLifecycleState] {
        if let dock = DockSplitStore.liveStore(containingPanel: id) {
            return dock.agentRuntimeByPanelId[id]?.agentLifecycleStates ?? [:]
        }
        return surface.owningWorkspace()?.agentLifecycleStatesByPanelId[id] ?? [:]
    }
}
