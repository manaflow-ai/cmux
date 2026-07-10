import Foundation

// libproc snapshots are a short-lived platform bridge shared by the CLI, socket,
// and Task Manager paths; keep the cache here so ownership stays with capture().
private nonisolated let cmuxTopProcessSnapshotCaptureCoordinator = CmuxTopProcessSnapshotCaptureCoordinator()

nonisolated extension CmuxTopProcessSnapshot {
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

    /// Captures after any physical capture that was already running when this call began.
    static func captureCoordinatedFresh(
        includeProcessDetails: Bool = false,
        includeCMUXScope: Bool = true
    ) -> CmuxTopProcessSnapshot {
        cmuxTopProcessSnapshotCaptureCoordinator.captureCoordinatedFresh(
            includeProcessDetails: includeProcessDetails,
            includeCMUXScope: includeCMUXScope
        )
    }
}
