import CmuxWorkspaces
import Foundation

@MainActor
extension AgentContextManagementCoordinator {
    /// Marks pending automation as cancelled when the user types.
    func userDidType(panelId: UUID) {
        // A user event can race a transfer and briefly arrive before the new
        // owner is discoverable. Cancel the old state directly so automation
        // cannot regain the keyboard during that handoff.
        let owner = owner(for: panelId, preferredWorkspaceID: nil)
        let binding = owner?.binding(panelId: panelId)
        let hasPendingRecovery = states[panelId].map {
            $0.pressure.isUnderPressure
                || $0.preservationAwaitingAcknowledgement
                || $0.injectionInFlight
        } ?? false
        if hasPendingRecovery {
            // Record the edge before any owner/binding lookup can fail during
            // detach/attach. `bindingDidChange` consumes it at the destination.
            // Idle clicks and focus/shortcut edges do not need this latch.
            userInputObservedBeforePressure.insert(panelId)
        }

        guard let owner, binding != nil else {
            guard var state = states[panelId] else { return }
            _ = cancelPendingRecovery(panelId: panelId, state: &state, owner: nil)
            states[panelId] = state
            return
        }
        guard var state = states[panelId] else {
            _ = owner.resetContextPressureDetector(panelId: panelId)
            owner.clearPressureStatus(key: Self.statusKey(for: panelId), panelId: panelId)
            return
        }
        let hadPendingRecovery = cancelPendingRecovery(
            panelId: panelId,
            state: &state,
            owner: owner
        )
        states[panelId] = state
        guard hadPendingRecovery else { return }
        structuredLog("user-input-cancelled", workspaceID: nil, surfaceID: panelId, detail: "context recovery cancelled")
        // Re-evaluate immediately so any surviving owner/binding state is
        // reconciled at the user-input boundary rather than on a later event.
        evaluate(surfaceID: panelId, owner: owner)
    }

    @discardableResult
    func cancelPendingRecovery(
        panelId: UUID,
        state: inout PanelState,
        owner: PanelOwner?
    ) -> Bool {
        cancelPreservationVerification(panelId: panelId)
        let hadPendingRecovery = state.pressure.isUnderPressure
            || state.preservationAwaitingAcknowledgement
            || state.injectionInFlight
        let shouldNotifyUnsafeClear = hadPendingRecovery
            && settings.action == .clear
        if shouldNotifyUnsafeClear, let owner {
            // Preserve the cancellation evidence long enough to surface the
            // destructive-action warning. The reset below intentionally clears
            // pressure, so notifying only after it would lose the reason.
            notifyUnsafeClear(
                owner: owner,
                surfaceID: panelId,
                reason: .userInputObserved
            )
        }
        // A click or other explicit-input edge can arrive while the pane is
        // otherwise idle. Only latch the cancellation when there was pending
        // recovery work; an idle interaction must not suppress a later
        // pressure episode until an unrelated lifecycle boundary.
        if hadPendingRecovery {
            state.userInputObserved = true
        }
        state.injectionInFlight = false
        state.pressure = AgentContextPressureSnapshot()
        state.pressureConfirmation.reset()
        state.providerEvidenceConfirmed = false
        state.providerEvidenceReceivedAt = nil
        state.preservationCompleted = false
        state.preservationAwaitingAcknowledgement = false
        state.preservationObservedRunning = false
        state.preservationHandoffPath = nil
        state.preservationRequestedAt = nil
        state.preservationVerificationInFlight = false
        state.recoveryAwaitingLifecycleBoundary = false
        state.recoveryObservedRunning = false
        state.unsafeClearNotificationSent = shouldNotifyUnsafeClear && owner != nil
        if shouldNotifyUnsafeClear {
            state.manualRecoveryRequired = true
        }
        if let owner {
            let resetGeneration = owner.resetContextPressureDetector(panelId: panelId)
            state.detectorGeneration = max(state.detectorGeneration, resetGeneration)
            if hadPendingRecovery {
                owner.clearPressureStatus(key: Self.statusKey(for: panelId), panelId: panelId)
            }
        }
        return hadPendingRecovery
    }
}
