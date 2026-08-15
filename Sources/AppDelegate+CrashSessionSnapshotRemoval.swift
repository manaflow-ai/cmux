import Foundation

extension AppDelegate {
    func syncManualRestoreSnapshotCachePruningCrashDiagnostics() {
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
            _ = sessionSnapshotStore.save(prunedSnapshot, fileURL: backupURL)
        case .missing:
            if !Self.hasCrashOnlyPrimarySnapshotRemovalMarker() {
                sessionSnapshotStore.removeSnapshot(fileURL: backupURL)
            }
        case .unusable:
            Self.clearCrashOnlyPrimarySnapshotRemovalMarker()
        }
    }

    private nonisolated static var crashOnlyPrimarySnapshotRemovalDefaultsKey: String {
        "cmux.session.crashOnlyPrimarySnapshotRemoval.v1"
    }

    nonisolated static func markCrashOnlyPrimarySnapshotRemoval(
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: crashOnlyPrimarySnapshotRemovalDefaultsKey)
    }

    nonisolated static func hasCrashOnlyPrimarySnapshotRemovalMarker(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: crashOnlyPrimarySnapshotRemovalDefaultsKey)
    }

    nonisolated static func clearCrashOnlyPrimarySnapshotRemovalMarker(
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: crashOnlyPrimarySnapshotRemovalDefaultsKey)
    }
}
