import CmuxWorkspaces
import Foundation

@MainActor
extension AgentContextManagementCoordinator {
    func lifecycleDidChange(
        key: String,
        panelId: UUID,
        lifecycle: AgentHibernationLifecycleState
    ) {
        // Feed owns a transient `needsInput` lifecycle key that is deliberately
        // outside the managed-provider namespace. It still represents a modal
        // dialog for this panel, so re-evaluate pending recovery immediately;
        // `evaluate` reads the authoritative owner map and fails closed.
        guard AgentContextProvider(managedAgentKind: key) != nil else {
            if states[panelId]?.pressure.isUnderPressure == true,
               let owner = owner(for: panelId, preferredWorkspaceID: nil) {
                structuredLog(
                    "lifecycle.ignored",
                    workspaceID: owner.workspaceID,
                    surfaceID: panelId,
                    detail: "non-provider-key=\(key) lifecycle=\(lifecycle.rawValue)"
                )
                evaluate(surfaceID: panelId, owner: owner)
            }
            return
        }
        updateLifecycle(
            AgentContextLifecycleState(rawValue: lifecycle.rawValue) ?? .unknown,
            key: key,
            panelId: panelId
        )
    }

    /// Receives authoritative lifecycle updates from managed-agent hooks.
    func updateLifecycle(
        _ lifecycle: AgentContextLifecycleState,
        key: String,
        panelId: UUID
    ) {
        guard let owner = owner(for: panelId, preferredWorkspaceID: nil),
              let binding = owner.binding(panelId: panelId),
              let provider = AgentContextProvider(managedAgentKind: binding.kind) else {
            resetForUnboundSession(panelId: panelId)
            return
        }
        owner.setContextPressureMonitoringEnabled(
            panelId: panelId,
            enabled: settings.isEnabled
        )
        guard AgentContextProvider(managedAgentKind: key) == provider else {
            structuredLog(
                "lifecycle.ignored",
                workspaceID: owner.workspaceID,
                surfaceID: panelId,
                detail: "provider-mismatch key=\(key) bound=\(provider.rawValue)"
            )
            // Feed and other attention owners use their own lifecycle keys.
            // They do not replace the provider's idle/running evidence, but a
            // needs-input value still opens a dialog and must immediately
            // re-evaluate any pending recovery.
            if states[panelId]?.pressure.isUnderPressure == true {
                evaluate(surfaceID: panelId, owner: owner)
            }
            return
        }
        var state = resolvedPanelState(
            panelId: panelId,
            provider: provider,
            binding: binding,
            owner: owner
        )
        let previousLifecycle = state.lifecycle
        state.binding = binding
        state.lifecycleByKey[key] = lifecycle
        state.lifecycle = Self.effectiveLifecycle(from: state.lifecycleByKey.values)
        state.dialogOpen = state.lifecycle == .needsInput
        if state.pressure.isUnderPressure {
            state.pressureConfirmation.observeLifecycle(state.lifecycle)
        }
        var preservationVerificationRequest: (URL, Date)?
        var preservationVerificationUnavailable = false
        if state.preservationAwaitingAcknowledgement, state.lifecycle == .running {
            state.preservationObservedRunning = true
        }
        if state.preservationAwaitingAcknowledgement,
           state.preservationObservedRunning,
           state.lifecycle == .idle {
            state.preservationObservedRunning = false
            if !state.preservationVerificationInFlight,
               !state.unsafeClearNotificationSent,
               let path = state.preservationHandoffPath,
               let requestedAt = state.preservationRequestedAt {
                state.preservationVerificationInFlight = true
                preservationVerificationRequest = (path, requestedAt)
            } else if state.preservationHandoffPath == nil || state.preservationRequestedAt == nil {
                state.unsafeClearNotificationSent = true
                preservationVerificationUnavailable = true
                structuredLog(
                    "preservation.rejected",
                    workspaceID: owner.workspaceID,
                    surfaceID: panelId,
                    detail: "handoff-file=path-unavailable"
                )
            }
        }
        if state.recoveryAwaitingLifecycleBoundary, state.lifecycle == .running {
            state.recoveryObservedRunning = true
        }
        if state.recoveryAwaitingLifecycleBoundary,
           state.recoveryObservedRunning,
           state.lifecycle == .idle {
            state.recoveryAwaitingLifecycleBoundary = false
            state.recoveryObservedRunning = false
            structuredLog(
                "recovery.rearmed",
                workspaceID: owner.workspaceID,
                surfaceID: panelId,
                detail: "lifecycle-idle"
            )
        }
        if (previousLifecycle == .running || previousLifecycle == .needsInput),
           state.lifecycle == .idle,
           state.userInputObserved {
            // A user turn has now completed. Discard any output that arrived
            // during it and reset the serialized tee before considering new
            // pressure at the fresh prompt.
            state.pressure = AgentContextPressureSnapshot()
            state.pressureConfirmation.reset()
            let resetGeneration = owner.resetContextPressureDetector(panelId: panelId)
            state.detectorGeneration = max(state.detectorGeneration, resetGeneration)
            state.userInputObserved = false
            state.unsafeClearNotificationSent = false
            userInputObservedBeforePressure.remove(panelId)
            owner.clearPressureStatus(key: Self.statusKey(for: panelId), panelId: panelId)
            structuredLog(
                "user-input-rearmed",
                workspaceID: owner.workspaceID,
                surfaceID: panelId,
                detail: "lifecycle-idle"
            )
        }
        states[panelId] = state
        if let (path, requestedAt) = preservationVerificationRequest {
            beginPreservationVerification(
                panelId: panelId,
                path: path,
                requestedAt: requestedAt
            )
        }
        if preservationVerificationUnavailable {
            notifyUnsafeClear(
                owner: owner,
                surfaceID: panelId,
                reason: .preservationUnavailable
            )
        }
        evaluate(surfaceID: panelId, owner: owner)
    }

    /// Receives shell prompt state without requiring the shell to be idle for a TUI agent.
    func updateShell(_ shellActivity: PanelShellActivityState, panelId: UUID) {
        guard let owner = owner(for: panelId, preferredWorkspaceID: nil),
              let binding = owner.binding(panelId: panelId),
              let provider = AgentContextProvider(managedAgentKind: binding.kind) else {
            resetForUnboundSession(panelId: panelId)
            return
        }
        owner.setContextPressureMonitoringEnabled(
            panelId: panelId,
            enabled: settings.isEnabled
        )
        var state = resolvedPanelState(
            panelId: panelId,
            provider: provider,
            binding: binding,
            owner: owner
        )
        state.binding = binding
        state.shellActivity = shellActivity
        states[panelId] = state
        evaluate(surfaceID: panelId, owner: owner)
    }

    func shellDidChange(panelId: UUID, state: PanelShellActivityState) {
        updateShell(state, panelId: panelId)
    }

    /// Called when lifecycle evidence is removed. Unknown is intentional:
    /// stale `.idle` evidence must not authorize a destructive command.
    func lifecycleDidClear(key: String? = nil, panelId: UUID) {
        guard var state = states[panelId] else { return }
        if let key {
            guard AgentContextProvider(managedAgentKind: key) == state.provider else {
                if let owner = owner(for: panelId, preferredWorkspaceID: nil),
                   state.pressure.isUnderPressure {
                    evaluate(surfaceID: panelId, owner: owner)
                }
                return
            }
            state.lifecycleByKey.removeValue(forKey: key)
        } else {
            state.lifecycleByKey.removeAll(keepingCapacity: true)
        }
        state.lifecycle = Self.effectiveLifecycle(from: state.lifecycleByKey.values)
        state.dialogOpen = state.lifecycle == .needsInput
        if state.lifecycle == .unknown {
            state.pressureConfirmation.reset()
            cancelPreservationVerification(panelId: panelId)
            state.preservationAwaitingAcknowledgement = false
            state.preservationObservedRunning = false
            state.preservationCompleted = false
            state.preservationHandoffPath = nil
            state.preservationRequestedAt = nil
            state.preservationVerificationInFlight = false
            state.recoveryAwaitingLifecycleBoundary = false
            state.recoveryObservedRunning = false
        }
        states[panelId] = state
        if let owner = owner(for: panelId, preferredWorkspaceID: nil) {
            evaluate(surfaceID: panelId, owner: owner)
        }
    }

    /// Reuses the generation and session-boundary rules shared by lifecycle
    /// and shell callbacks, so neither event path can drift in its gating
    /// evidence or detector reset behavior.
    private func resolvedPanelState(
        panelId: UUID,
        provider: AgentContextProvider,
        binding: SurfaceResumeBindingSnapshot,
        owner: PanelOwner
    ) -> PanelState {
        let existingState = states[panelId]
        let stateGeneration: UInt64
        if let existingState,
           existingState.provider == provider,
           sameSession(existingState.binding, binding) {
            stateGeneration = existingState.detectorGeneration
        } else if existingState == nil {
            // Lifecycle evidence can be the first coordinator signal. Do not
            // reset a live detector here or a pressure event already queued
            // for this runtime would be rejected as stale.
            stateGeneration = owner.contextPressureDetectorGeneration(panelId: panelId)
        } else {
            stateGeneration = owner.resetContextPressureDetector(panelId: panelId)
        }
        var state = existingState
            .flatMap { existing in
                existing.provider == provider && sameSession(existing.binding, binding)
                    ? existing
                    : nil
            }
            ?? makePanelState(
                panelId: panelId,
                provider: provider,
                binding: binding,
                owner: owner,
                detectorGeneration: stateGeneration,
                seedLifecycleEvidence: existingState == nil
            )
        if userInputObservedBeforePressure.remove(panelId) != nil {
            _ = cancelPendingRecovery(panelId: panelId, state: &state, owner: owner)
        }
        return state
    }
}
