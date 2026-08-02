import Foundation

struct TerminalSurfaceRuntimeOwnershipAdmissionState {
    var reservationIDs: Set<UUID> = []
    var closeTeardownDegraded = false
    var recoveryEntriesByID:
        [UUID: TerminalSurfaceRuntimeOwnershipRecoveryEntry] = [:]
    var recoveryHeadID: UUID?
    var recoveryTailID: UUID?
}
