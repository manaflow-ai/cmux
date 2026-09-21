import CmuxWorkspaces
import Foundation

extension SurfaceResumeBindingSnapshot {
    /// Arms explicit in-memory observation for a restored process binding.
    mutating func armRestoredProcessDetectionObservation() {
        guard isProcessDetected else { return }
        var observation = RestoredProcessDetectionObservation()
        observation.arm()
        restoredProcessDetectionObservation = observation
    }

    /// Returns whether this binding remains protected from an empty process scan.
    func preservesRestoredProcessDetection() -> Bool {
        isProcessDetected && restoredProcessDetectionObservation?.preserves() == true
    }

    /// Ends restore observation after authoritative evidence.
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
