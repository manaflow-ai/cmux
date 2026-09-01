import Foundation
import CmuxControlSocket

@MainActor
extension AgentStallSupervisor {
    /// Starts a capture for a new managed turn, while treating the repeated
    /// `.running` lifecycle notifications emitted by per-tool hooks as
    /// presentation-only updates. A retry injection deliberately enters the
    /// `.retrying` phase, so its next `.running` event still opens a fresh
    /// generation and preserves the retry budget.
    func handleRunningLifecycle(
        owner: ControlSidebarPanelOwner,
        panelID: UUID,
        provider: String,
        binding: SurfaceResumeBindingSnapshot,
        state incomingState: AgentStallSupervisorPanelState,
        sameSession: Bool,
        identity: ControlSidebarLifecycleIdentity?
    ) {
        var state = incomingState
        let reportedTurnID = identity?.turnID
        let sameTurn = state.turnID == nil || reportedTurnID == nil || state.turnID == reportedTurnID
        let sameTerminalGeneration = state.terminalLifecycleID == nil
            || identity?.terminalLifecycleID == nil
            || state.terminalLifecycleID == identity?.terminalLifecycleID
        if sameSession, sameTurn, sameTerminalGeneration,
           state.lifecycle == .running, state.phase == .running {
            // Claude's PreToolUse and Codex's intermediate status hooks can
            // report running many times during one turn. Resetting the tail
            // here would make the final Stop banner depend on hook timing.
            if let process = owner.agentStallProcessIdentity(
                provider: provider,
                checkpointID: binding.checkpointId ?? "",
                panelID: panelID
            ) {
                if state.processID != process.pid || state.processIdentity != process.identity {
                    // A repeated hook is presentation-only; it must never
                    // silently retarget the capture to a reused/replaced
                    // provider process. The next real running hook establishes
                    // a fresh generation after ownership is proven again.
                    cancel(panelID: panelID, reason: "process-generation-replaced")
                    return
                }
                state.processID = process.pid
                state.processIdentity = process.identity
            }
            statesByPanelID[panelID] = state
            Self.logger.debug(
                "event=lifecycle-duplicate provider=\(provider, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(state.generation) state=running reason=turn-still-open"
            )
            return
        }

        let preservingRetry = sameSession
            && state.phase == .retrying
            && state.retryAttempts > 0
        let process = owner.agentStallProcessIdentity(
            provider: provider,
            checkpointID: binding.checkpointId ?? "",
            panelID: panelID
        )
        state.retryScheduler?.cancel()
        state.retryScheduler = nil
        state.retryToken = nil
        state.generation &+= 1
        state.lifecycle = .running
        state.phase = .running
        state.boundaryCommitment = .open
        state.pendingBoundary = nil
        state.processID = process?.pid
        state.processIdentity = process?.identity
        state.sessionID = identity?.sessionID ?? binding.checkpointId
        state.turnID = reportedTurnID
        state.terminalLifecycleID = identity?.terminalLifecycleID
        if !preservingRetry { state.retryAttempts = 0 }
        statesByPanelID[panelID] = state
        let hasOutputCapture: Bool
        if settings.isEnabled {
            hasOutputCapture = outputDemand.beginCapture(
                AgentStallOutputDemandDescriptor(
                    workspaceID: owner.id,
                    epoch: state.generation
                ),
                for: panelID
            )
        } else {
            outputDemand.clearCapture(for: panelID)
            hasOutputCapture = false
        }
        if !hasOutputCapture {
            Self.logger.warning(
                "event=capture-unavailable provider=\(provider, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(state.generation)"
            )
        }
        presentation.clearStatus(owner: owner, panelID: panelID)
        Self.logger.info(
            "event=lifecycle provider=\(provider, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(state.generation) state=running"
        )
    }

    /// Revalidates a newly published binding without creating a turn boundary.
    func bindingDidChange(owner: ControlSidebarPanelOwner, panelID: UUID) {
        guard let binding = owner.agentStallResumeBinding(panelID),
              binding.hasCompleteManagedSessionIdentity,
              supportedProvider(kind: binding.kind, key: binding.kind ?? "") != nil else {
            cancel(panelID: panelID, reason: "binding-cleared")
            return
        }
        guard var state = statesByPanelID[panelID] else { return }
        if let previousOwner = state.ownerToken,
           previousOwner != owner.agentStallOwnerToken {
            // Output descriptors include the owning workspace. A pane move is
            // therefore a hard capture boundary; the next running hook will
            // establish fresh ownership in the destination.
            cancel(panelID: panelID, reason: "owner-transferred")
            return
        }
        if state.binding?.isSameManagedSession(as: binding) != true {
            cancel(panelID: panelID, reason: "binding-replaced")
            return
        }
        state.ownerToken = owner.agentStallOwnerToken
        state.binding = binding
        statesByPanelID[panelID] = state
    }

    /// Binding teardown is cancellation, never proof of a prompt boundary.
    func bindingDidClear(panelID: UUID) {
        cancel(panelID: panelID, reason: "binding-cleared")
    }

    /// Cancels recovery before physical, socket, or CLI input is sent.
    func explicitInputDidBegin(panelID: UUID) {
        guard !internalInputPanelIDs.contains(panelID) else { return }
        cancel(panelID: panelID, reason: "user-input")
    }

    /// Drops all evidence when a panel runtime is destroyed.
    func panelDidClose(panelID: UUID) {
        cancel(panelID: panelID, reason: "panel-closed")
    }
}
