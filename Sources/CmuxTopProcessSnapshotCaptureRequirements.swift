import Foundation

/// Fields that make one process snapshot richer than its base resource record.
struct CmuxTopProcessSnapshotCaptureRequirements: Sendable {
    let includeProcessDetails: Bool
    let includeCMUXScope: Bool

    func satisfies(_ requested: Self) -> Bool {
        (includeProcessDetails || !requested.includeProcessDetails) &&
            (includeCMUXScope || !requested.includeCMUXScope)
    }
}
