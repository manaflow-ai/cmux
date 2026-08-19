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
        guard let owner, owner.binding(panelId: panelId) != nil else {
            return
        }
        userInputObservedBeforePressure.insert(panelId)
        guard var state = states[panelId] else {
            _ = owner.resetContextPressureDetector(panelId: panelId)
            owner.clearPressureStatus(key: Self.statusKey(for: panelId), panelId: panelId)
            return
        }
        cancelPreservationVerification(panelId: panelId)
        let hadPendingRecovery = state.pressure.isUnderPressure
            || state.preservationAwaitingAcknowledgement
            || state.injectionInFlight
        state.userInputObserved = true
        state.injectionInFlight = false
        state.pressure = AgentContextPressureSnapshot()
        state.preservationCompleted = false
        state.preservationAwaitingAcknowledgement = false
        state.preservationObservedRunning = false
        state.preservationHandoffPath = nil
        state.preservationRequestedAt = nil
        state.preservationVerificationInFlight = false
        state.recoveryAwaitingLifecycleBoundary = false
        state.recoveryObservedRunning = false
        state.unsafeClearNotificationSent = false
        let resetGeneration = owner.resetContextPressureDetector(panelId: panelId)
        state.detectorGeneration = max(state.detectorGeneration, resetGeneration)
        if hadPendingRecovery {
            owner.clearPressureStatus(key: Self.statusKey(for: panelId), panelId: panelId)
        }
        states[panelId] = state
        guard hadPendingRecovery else { return }
        structuredLog("user-input-cancelled", workspaceID: nil, surfaceID: panelId, detail: "context recovery cancelled")
        // Re-evaluate immediately so a destructive action that is now unsafe
        // surfaces its notification at the user-input boundary, rather than
        // waiting for an unrelated lifecycle or settings event.
        evaluate(surfaceID: panelId, owner: owner)
    }
}
