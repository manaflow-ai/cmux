import Foundation
import CmuxFoundation
import OSLog

@MainActor
extension AgentStallSupervisor {
    func scheduleRetry(
        owner: ControlSidebarPanelOwner,
        panelID: UUID,
        binding: SurfaceResumeBindingSnapshot,
        provider: String,
        generation: UInt64,
        attempt: Int,
        maximumAttempts: Int,
        delaySeconds: Int,
        actionID: String,
        input: String
    ) {
        guard var state = statesByPanelID[panelID],
              let processID = state.processID,
              let processIdentity = state.processIdentity else {
            cancel(panelID: panelID, reason: "missing-process-generation")
            return
        }
        state.retryScheduler?.cancel()

        let token = UUID()
        let request = AgentStallRetryRequest(
            ownerToken: owner.agentStallOwnerToken,
            workspaceID: owner.id,
            panelID: panelID,
            binding: binding,
            provider: provider,
            generation: generation,
            attempt: attempt,
            maximumAttempts: maximumAttempts,
            actionID: actionID,
            input: input,
            processID: processID,
            processIdentity: processIdentity,
            token: token
        )
        state.retryToken = token
        state.phase = .retryWaiting
        // A cancellation-aware scheduler owns this genuine backoff deadline;
        // it never polls or waits for state to settle. The injected clock keeps
        // the transition deterministic in tests.
        let scheduler = state.retryScheduler
            ?? MainActorDeferredActionScheduler(clock: retryClock)
        state.retryScheduler = scheduler
        statesByPanelID[panelID] = state
        scheduler.schedule(after: .seconds(delaySeconds)) { [weak self] in
            self?.injectRetry(request)
        }

        presentation.setRetryStatus(
            owner: owner,
            panelID: panelID,
            provider: provider,
            attempt: attempt,
            maximumAttempts: maximumAttempts
        )
        Self.logger.info(
            "event=retry-scheduled provider=\(provider, privacy: .public) action=\(actionID, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(generation) attempt=\(attempt) maximumAttempts=\(maximumAttempts) delaySeconds=\(delaySeconds)"
        )
    }

    private func injectRetry(_ request: AgentStallRetryRequest) {
        guard var state = statesByPanelID[request.panelID],
              state.retryToken == request.token,
              state.generation == request.generation,
              state.phase == .retryWaiting,
              settings.isEnabled,
              let owner = resolveOwner(
                  panelID: request.panelID,
                  preferredWorkspaceID: request.workspaceID
              ),
              owner.agentStallOwnerToken == request.ownerToken,
              owner.containsAgentStallPanel(request.panelID),
              let currentBinding = owner.agentStallResumeBinding(request.panelID),
              currentBinding.isSameManagedSession(as: request.binding),
              owner.agentStallMatchesProcessGeneration(
                  provider: request.provider,
                  checkpointID: request.binding.checkpointId ?? "",
                  panelID: request.panelID,
                  recordedPID: request.processID,
                  recordedIdentity: request.processIdentity
              ),
              owner.agentStallProcessLiveness(
                  provider: request.provider,
                  checkpointID: request.binding.checkpointId ?? "",
                  panelID: request.panelID,
                  recordedPID: request.processID,
                  recordedIdentity: request.processIdentity
              ) == .running,
              let panel = owner.agentStallPanel(request.panelID) else {
            cancel(panelID: request.panelID, reason: "retry-revalidation-failed")
            return
        }
        let lifecycle = owner.agentStallLifecycle(
            key: request.provider == "claude" ? "claude_code" : request.provider,
            panelID: request.panelID
        )
        guard lifecycle == .idle || lifecycle == .needsInput else {
            cancel(panelID: request.panelID, reason: "retry-prompt-not-idle")
            return
        }

        internalInputPanelIDs.insert(request.panelID)
        let result = panel.sendInputResult(request.input)
        internalInputPanelIDs.remove(request.panelID)
        guard result.accepted else {
            markExhausted(
                owner: owner,
                panelID: request.panelID,
                generation: request.generation,
                reason: "input-rejected"
            )
            return
        }

        state.phase = .retrying
        state.retryAttempts = request.attempt
        let scheduler = state.retryScheduler
            ?? MainActorDeferredActionScheduler(clock: retryClock)
        state.retryScheduler = scheduler
        statesByPanelID[request.panelID] = state
        presentation.clearStatus(owner: owner, panelID: request.panelID)
        scheduler.schedule(after: retryAcknowledgementTimeout) { [weak self] in
            self?.retryAcknowledgementTimedOut(request)
        }
        Self.logger.info(
            "event=retry-injected provider=\(request.provider, privacy: .public) action=\(request.actionID, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(request.panelID, privacy: .public) generation=\(request.generation) attempt=\(request.attempt) maximumAttempts=\(request.maximumAttempts)"
        )
    }

    /// Fails closed when accepted retry bytes do not produce a fresh running
    /// hook within the bounded acknowledgement window. Acceptance by the
    /// terminal transport alone is not proof that the provider recalled the
    /// prompt, so the user receives the same exhausted-retry guidance as any
    /// other terminal recovery failure.
    private func retryAcknowledgementTimedOut(_ request: AgentStallRetryRequest) {
        guard let state = statesByPanelID[request.panelID],
              state.phase == .retrying,
              state.retryToken == request.token,
              state.generation == request.generation else {
            return
        }
        guard let owner = resolveOwner(
            panelID: request.panelID,
            preferredWorkspaceID: request.workspaceID
        ) else {
            cancel(panelID: request.panelID, reason: "retry-ack-owner-missing")
            return
        }
        guard owner.agentStallOwnerToken == request.ownerToken,
              owner.containsAgentStallPanel(request.panelID),
              let currentBinding = owner.agentStallResumeBinding(request.panelID),
              currentBinding.isSameManagedSession(as: request.binding) else {
            cancel(panelID: request.panelID, reason: "retry-ack-revalidation-failed")
            return
        }
        markExhausted(
            owner: owner,
            panelID: request.panelID,
            generation: request.generation,
            reason: "retry-ack-timeout"
        )
    }

    func markExhausted(
        owner: ControlSidebarPanelOwner,
        panelID: UUID,
        generation: UInt64,
        reason: String
    ) {
        if var state = statesByPanelID[panelID] {
            state.retryScheduler?.cancel()
            state.retryScheduler = nil
            state.retryToken = nil
            state.phase = .exhausted
            statesByPanelID[panelID] = state
        }
        presentation.presentRetryExhausted(
            owner: owner,
            panelID: panelID,
            generation: generation
        )
        Self.logger.error(
            "event=retry-exhausted workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(generation) reason=\(reason, privacy: .public)"
        )
    }
}
