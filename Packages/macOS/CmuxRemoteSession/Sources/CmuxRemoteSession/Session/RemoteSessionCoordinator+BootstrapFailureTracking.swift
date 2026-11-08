internal import Foundation

extension RemoteSessionCoordinator {
    /// Clears bootstrap retry accounting after a transport reaches a healthy
    /// ready state or the coordinator is explicitly stopped/re-armed.
    func resetBootstrapFailureTrackingLocked() {
        bootstrapFailureFingerprint = nil
        bootstrapFailureCount = 0
        bootstrapFailureTotal = 0
    }
}
