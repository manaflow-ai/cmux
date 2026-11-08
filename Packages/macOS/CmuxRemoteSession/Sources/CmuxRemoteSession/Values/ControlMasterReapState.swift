internal import Foundation

/// Queue-confined lifecycle state for inherited-ControlMaster recovery.
struct ControlMasterReapState {
    var startupPhase = ReverseRelayStartupPhase.recoveryAvailable
    var observationTask: Task<Void, Never>?
    var observedControlPath: String?
    var lastHandledEventID: UUID?
}
