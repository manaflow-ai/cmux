import Foundation

extension TerminalPanel {
    var isAgentHibernated: Bool {
        agentHibernationPhase.isCommitted
    }

    var isAgentHibernationTerminating: Bool {
        agentHibernationPhase.isTerminating
    }

    var agentHibernationTerminationFailed: Bool {
        agentHibernationPhase.terminationFailed
    }

    var isAgentHibernationCommitPending: Bool {
        agentHibernationPhase.isAwaitingCommit
    }

    var agentHibernationState: AgentHibernationPanelState? {
        agentHibernationPhase.state
    }

    @discardableResult
    func enterAgentHibernation(
        agent: SessionRestorableAgentSnapshot,
        lastActivityAt: Date,
        hibernatedAt: Date = .now
    ) -> Bool {
        if isAgentHibernationCommitPending {
            completeAgentHibernationTermination()
            return true
        }
        let state = AgentHibernationPanelState(
            agent: agent,
            hibernatedAt: hibernatedAt,
            lastActivityAt: lastActivityAt
        )
        guard suspendRuntimeForAgentHibernation(reason: "agentHibernation") else {
            return false
        }
        agentHibernationPhase = .hibernated(state)
        return true
    }

    @discardableResult
    func beginAgentHibernationTermination(
        agent: SessionRestorableAgentSnapshot,
        lastActivityAt: Date,
        committedAt: Date = .now
    ) -> Bool {
        guard case .live = agentHibernationPhase else { return false }
        onRequestAgentHibernationTerminationRetry = nil
        let state = AgentHibernationPanelState(
            agent: agent,
            hibernatedAt: committedAt,
            lastActivityAt: lastActivityAt
        )
        guard suspendRuntimeForAgentHibernation(
            reason: "agentHibernation.terminating"
        ) else {
            return false
        }
        agentHibernationPhase = .terminating(state)
        return true
    }

    func completeAgentHibernationTermination() {
        let state: AgentHibernationPanelState
        switch agentHibernationPhase {
        case .terminating(let value),
             .recovering(let value),
             .terminationFailed(let value):
            state = value
        case .live, .hibernated:
            return
        }
        onRequestAgentHibernationTerminationRetry = nil
        agentHibernationPhase = .hibernated(state)
    }

    func beginAgentHibernationTerminationRecovery() {
        let state: AgentHibernationPanelState
        switch agentHibernationPhase {
        case .terminating(let value), .terminationFailed(let value):
            state = value
        case .live, .recovering, .hibernated:
            return
        }
        agentHibernationPhase = .recovering(state)
    }

    func failAgentHibernationTermination() {
        guard case .recovering(let state) = agentHibernationPhase else { return }
        agentHibernationPhase = .terminationFailed(state)
    }

    func discardAgentHibernationPhaseForPermanentClose() {
        onRequestAgentHibernationTerminationRetry = nil
        agentHibernationPhase = .live
    }

    func retryAgentHibernationTermination() {
        guard agentHibernationTerminationFailed else { return }
        onRequestAgentHibernationTerminationRetry?()
    }

    private func suspendRuntimeForAgentHibernation(reason: String) -> Bool {
        guard surface.suspendRuntimeSurfaceForAgentHibernation(reason: reason) else {
            return false
        }
        unfocus()
        searchState = nil
        hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)
        requestViewReattach()
        return true
    }

    @discardableResult
    func prepareAgentHibernationResume() -> AgentHibernationResumePreparation {
        guard case .hibernated(let state) = agentHibernationPhase else {
            return .unavailable
        }
        let resumeStartupInput = state.agent.resumeStartupInput()
        guard surface.prepareAgentHibernationResume(initialInput: resumeStartupInput) else {
            return .unavailable
        }
        agentHibernationPhase = .live
        requestViewReattach()
        surface.requestBackgroundSurfaceStartIfNeeded()
        return .resumed(queuedStartupInput: resumeStartupInput != nil)
    }
}
