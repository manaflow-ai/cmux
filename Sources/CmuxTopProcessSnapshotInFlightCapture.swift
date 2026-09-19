import Foundation

/// Mutable completion cell for one synchronous process census generation.
final class CmuxTopProcessSnapshotInFlightCapture {
    let sequence: UInt64
    let requirements: CmuxTopProcessSnapshotCaptureRequirements
    let startedAt: Date
    var snapshot: CmuxTopProcessSnapshot?

    init(
        sequence: UInt64,
        requirements: CmuxTopProcessSnapshotCaptureRequirements,
        startedAt: Date
    ) {
        self.sequence = sequence
        self.requirements = requirements
        self.startedAt = startedAt
    }
}
