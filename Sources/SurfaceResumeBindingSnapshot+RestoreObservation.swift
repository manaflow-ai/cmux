import Foundation

extension SurfaceResumeBindingSnapshot {
    /// Arms the bounded in-memory observation window for a restored process binding.
    mutating func armRestoredProcessDetectionObservation(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard isProcessDetected else { return }
        restoredProcessDetectionDeadlineUptime = nowUptime +
            SessionPersistencePolicy.autosaveInterval * 3
    }

    /// Returns whether this binding remains protected from an empty process scan.
    func preservesRestoredProcessDetection(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        isProcessDetected &&
            restoredProcessDetectionDeadlineUptime.map { nowUptime < $0 } == true
    }

    /// Ends the temporary restore observation window after authoritative evidence.
    mutating func clearRestoredProcessDetectionObservation() {
        restoredProcessDetectionDeadlineUptime = nil
    }
}
