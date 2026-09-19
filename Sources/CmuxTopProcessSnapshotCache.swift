import Foundation

/// One process-wide owner for all synchronous process snapshot callers.
/// The coordinator is intentionally bounded to one result and one in-flight
/// generation; no negative process or scope results are retained here.
nonisolated let cmuxTopProcessSnapshotCaptureCoordinator =
    CmuxTopProcessSnapshotCaptureCoordinator(
        captureProvider: { includeProcessDetails, includeCMUXScope in
            CmuxTopProcessSnapshot.captureUncoordinated(
                includeProcessDetails: includeProcessDetails,
                includeCMUXScope: includeCMUXScope
            )
        }
    )

extension CmuxTopProcessSnapshot {
    static func captureCached(
        includeProcessDetails: Bool = false,
        includeCMUXScope: Bool = true,
        maximumAge: TimeInterval
    ) -> CmuxTopProcessSnapshot {
        cmuxTopProcessSnapshotCaptureCoordinator.captureCached(
            includeProcessDetails: includeProcessDetails,
            includeCMUXScope: includeCMUXScope,
            maximumAge: maximumAge
        )
    }
}
