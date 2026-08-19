import Foundation
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
        state.retryTimer?.invalidate()

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
        // A one-shot RunLoop timer is the cancellable event source for this
        // genuine backoff deadline; it never polls or waits for state to settle.
        let timer = Timer(timeInterval: TimeInterval(delaySeconds), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.injectRetry(request)
            }
        }
        state.retryTimer = timer
        statesByPanelID[panelID] = state
        RunLoop.main.add(timer, forMode: .common)

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
        state.retryTimer = nil
        statesByPanelID[request.panelID] = state
        presentation.clearStatus(owner: owner, panelID: request.panelID)
        Self.logger.info(
            "event=retry-injected provider=\(request.provider, privacy: .public) action=\(request.actionID, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(request.panelID, privacy: .public) generation=\(request.generation) attempt=\(request.attempt) maximumAttempts=\(request.maximumAttempts)"
        )
    }

    func markExhausted(
        owner: ControlSidebarPanelOwner,
        panelID: UUID,
        generation: UInt64,
        reason: String
    ) {
        if var state = statesByPanelID[panelID] {
            state.retryTimer?.invalidate()
            state.retryTimer = nil
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
