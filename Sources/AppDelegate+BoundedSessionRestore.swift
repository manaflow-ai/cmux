import Foundation
import CmuxControlSocket

extension AppDelegate {
    /// Applies the restore structure bounds to the app's own snapshot and
    /// leaves a breadcrumb when they removed anything, so a trimmed session
    /// is explainable after the fact.
    static func boundedSnapshotForRestore(
        _ snapshot: AppSessionSnapshot,
        phase: String
    ) -> AppSessionSnapshot {
        let (bounded, report) = SessionSnapshotImportTrust.snapshotForRestore(
            snapshot,
            source: .channel(phase)
        )
        if report.droppedWindowCount + report.droppedWorkspaceCount + report.droppedPanelCount > 0 {
            StartupBreadcrumbLog.append(
                "session.restore.bounded",
                fields: [
                    "phase": phase,
                    "dropped_windows": String(report.droppedWindowCount),
                    "dropped_workspaces": String(report.droppedWorkspaceCount),
                    "dropped_panels": String(report.droppedPanelCount),
                ]
            )
        }
        return bounded
    }

    @discardableResult
    func reopenPreviousSession(shouldActivate: Bool = true) -> Bool {
        guard let snapshot = sessionSnapshotStore.loadReopenSessionSnapshot(fileURL: nil) else {
            return false
        }
        return restorePreviousSessionSnapshot(snapshot, shouldActivate: shouldActivate)
    }

}
