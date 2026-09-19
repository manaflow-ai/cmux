import Foundation

extension AppDelegate {
    /// Returns whether a missing primary snapshot has an independent recovery
    /// signal. A clean missing primary still means the user intentionally began
    /// fresh, while an unclean launch or crash-only teardown marker means the
    /// `-previous` generation is the safe source of truth.
    nonisolated static func shouldRecoverMissingPrimarySessionSnapshot(
        previousLaunchWasUnclean: Bool,
        crashOnlyPrimarySnapshotRemovalMarker: Bool
    ) -> Bool {
        previousLaunchWasUnclean || crashOnlyPrimarySnapshotRemovalMarker
    }

    /// Synchronizes the manual-restore cache while preserving a known-good
    /// generation across an unclean launch. A primary snapshot can be valid JSON
    /// yet represent a partially completed restore; keeping the prior copy gives
    /// the user a rollback path and avoids destroying the only intact snapshot.
    func syncManualRestoreSnapshotCachePruningCrashDiagnostics(
        preserveExistingBackup: Bool = false
    ) {
        guard let primaryURL = sessionSnapshotStore.defaultSnapshotFileURL(),
              let backupURL = sessionSnapshotStore.manualRestoreSnapshotFileURL() else {
            return
        }
        switch sessionSnapshotStore.loadOutcome(fileURL: primaryURL) {
        case .loaded(let snapshot):
            Self.clearCrashOnlyPrimarySnapshotRemovalMarker()
            guard let prunedSnapshot = SessionPersistencePolicy
                .pruningCmuxCrashDiagnosticWindows(from: snapshot)
                .snapshot else {
                return
            }
            if preserveExistingBackup,
               case .loaded = sessionSnapshotStore.loadOutcome(fileURL: backupURL) {
                return
            }
            _ = sessionSnapshotStore.save(prunedSnapshot, fileURL: backupURL)
        case .missing:
            if !preserveExistingBackup && !Self.hasCrashOnlyPrimarySnapshotRemovalMarker() {
                sessionSnapshotStore.removeSnapshot(fileURL: backupURL)
            }
        case .unusable:
            Self.clearCrashOnlyPrimarySnapshotRemovalMarker()
        }
    }

    nonisolated static func markCrashOnlyPrimarySnapshotRemoval(
        defaults: UserDefaults = .standard
    ) {
        SessionSnapshotPersistenceWriter.markCrashOnlyPrimarySnapshotRemoval(defaults: defaults)
    }

    nonisolated static func hasCrashOnlyPrimarySnapshotRemovalMarker(
        defaults: UserDefaults = .standard
    ) -> Bool {
        SessionSnapshotPersistenceWriter.hasCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults)
    }

    nonisolated static func clearCrashOnlyPrimarySnapshotRemovalMarker(
        defaults: UserDefaults = .standard
    ) {
        SessionSnapshotPersistenceWriter.clearCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults)
    }
}
