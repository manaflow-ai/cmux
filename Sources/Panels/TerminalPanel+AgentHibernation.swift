import Foundation

extension TerminalPanel {
    var isAgentHibernated: Bool {
        agentHibernationPhase.isCommitted
    }

    var isAgentHibernationTerminating: Bool {
        agentHibernationPhase.isTerminating
    }

    var agentHibernationState: AgentHibernationPanelState? {
        agentHibernationPhase.state
    }

    func enterAgentHibernation(
        agent: SessionRestorableAgentSnapshot,
        lastActivityAt: Date,
        hibernatedAt: Date = .now
    ) {
        if isAgentHibernationTerminating {
            completeAgentHibernationTermination()
            return
        }
        agentHibernationPhase = .hibernated(AgentHibernationPanelState(
            agent: agent,
            hibernatedAt: hibernatedAt,
            lastActivityAt: lastActivityAt
        ))
        suspendRuntimeForAgentHibernation(reason: "agentHibernation")
    }

    func beginAgentHibernationTermination(
        agent: SessionRestorableAgentSnapshot,
        lastActivityAt: Date,
        committedAt: Date = .now
    ) {
        guard case .live = agentHibernationPhase else { return }
        agentHibernationPhase = .terminating(AgentHibernationPanelState(
            agent: agent,
            hibernatedAt: committedAt,
            lastActivityAt: lastActivityAt
        ))
        suspendRuntimeForAgentHibernation(reason: "agentHibernation.terminating")
    }

    func completeAgentHibernationTermination() {
        guard case .terminating(let state) = agentHibernationPhase else { return }
        agentHibernationPhase = .hibernated(state)
    }

    func discardAgentHibernationPhaseForPermanentClose() {
        agentHibernationPhase = .live
    }

    private func suspendRuntimeForAgentHibernation(reason: String) {
        unfocus()
        searchState = nil
        hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)
        surface.suspendRuntimeSurfaceForAgentHibernation(reason: reason)
        requestViewReattach()
    }

    @discardableResult
    func prepareAgentHibernationResume() -> AgentHibernationResumePreparation {
        guard case .hibernated(let state) = agentHibernationPhase else {
            return .unavailable
        }
        let resumeStartupInput = state.agent.resumeStartupInput()
        agentHibernationPhase = .live
        surface.prepareAgentHibernationResume(initialInput: resumeStartupInput)
        requestViewReattach()
        surface.requestBackgroundSurfaceStartIfNeeded()
        return .resumed(queuedStartupInput: resumeStartupInput != nil)
    }
}
