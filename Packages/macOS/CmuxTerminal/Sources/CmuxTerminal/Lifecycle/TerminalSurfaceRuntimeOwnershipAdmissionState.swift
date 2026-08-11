import Foundation

struct TerminalSurfaceRuntimeOwnershipAdmissionState {
    var reservationIDs: Set<UUID> = []
    /// Ingress slots held by live owners or by ordered control submissions.
    var ingressReservationIDs: Set<UUID> = []
    /// Owner slots that have not transferred to an enqueue submission.
    var unclaimedOwnershipIngressReservationIDs: Set<UUID> = []
    var closeTeardownDegraded = false
    var closeTeardownAllStalled = false
    var recoveryEntriesByID:
        [UUID: TerminalSurfaceRuntimeOwnershipRecoveryEntry] = [:]
    var recoveryCapacityReservationIDs: Set<UUID> = []
    var recoveryHeadID: UUID?
    var recoveryTailID: UUID?
    var pendingRecoveryFailureCount = 0
    var recoveryGrantIsScheduled = false
    var recoveryRescanRequested = false
}
