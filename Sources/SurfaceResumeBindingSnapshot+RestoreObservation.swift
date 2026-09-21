import CmuxWorkspaces
import Foundation

extension SurfaceResumeBindingSnapshot {
    /// Arms the bounded in-memory observation window for a restored process binding.
    mutating func armRestoredProcessDetectionObservation(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard isProcessDetected else { return }
        var observation = RestoredProcessDetectionObservation(
            interval: SessionPersistencePolicy.autosaveInterval * 3
        )
        observation.arm(nowUptime: nowUptime)
        restoredProcessDetectionObservation = observation
    }

    /// Returns whether this binding remains protected from an empty process scan.
    func preservesRestoredProcessDetection(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        isProcessDetected && restoredProcessDetectionObservation?.preserves(nowUptime: nowUptime) == true
    }

    /// Ends the temporary restore observation window after authoritative evidence.
    mutating func clearRestoredProcessDetectionObservation() {
        restoredProcessDetectionObservation = nil
    }

    /// Compares persisted binding identity while ignoring ephemeral restore observation state.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name &&
            lhs.kind == rhs.kind &&
            lhs.command == rhs.command &&
            lhs.cwd == rhs.cwd &&
            lhs.checkpointId == rhs.checkpointId &&
            lhs.source == rhs.source &&
            lhs.environment == rhs.environment &&
            lhs.launchCommand == rhs.launchCommand &&
            lhs.permissionMode == rhs.permissionMode &&
            lhs.autoResume == rhs.autoResume &&
            lhs.resumeEvidenceProvenance == rhs.resumeEvidenceProvenance &&
            lhs.approvalPolicy == rhs.approvalPolicy &&
            lhs.approvalRecordId == rhs.approvalRecordId &&
            lhs.launchFlavor == rhs.launchFlavor &&
            lhs.wasDecodedWithoutLaunchFlavor == rhs.wasDecodedWithoutLaunchFlavor &&
            lhs.updatedAt == rhs.updatedAt
    }
}
