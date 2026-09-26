import CmuxWorkspaces
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

    /// Archives the snapshot the previous launch left behind into the rotated
    /// history, then installs the overwrite guard with its richness as the
    /// baseline. That is the primary, or the `-previous` copy when the primary
    /// is missing or unusable (the case startup restore falls back on). Runs
    /// before the manual-restore sync and before any save, so every launch's
    /// starting layout is kept even if this launch restores nothing and is
    /// relaunched again right away.
    func archiveSessionSnapshotAndInstallOverwriteGuard(now: Date = Date()) {
        var baseline = SessionSnapshotRichness.empty
        let candidates = [
            sessionSnapshotStore.defaultSnapshotFileURL(),
            sessionSnapshotStore.manualRestoreSnapshotFileURL(),
        ].compactMap { $0 }
        for fileURL in candidates {
            guard case .loaded(let snapshot) = sessionSnapshotStore.loadOutcome(fileURL: fileURL) else { continue }
            baseline = snapshot.richness
            sessionSnapshotStore.archiveSnapshotToHistory(
                fileURL: fileURL,
                richness: snapshot.richness,
                archivedAt: now
            )
            break
        }
        sessionSnapshotOverwriteGuard = SessionSnapshotOverwriteGuard(baseline: baseline, launchDate: now)
#if DEBUG
        cmuxDebugLog(
            "session.history.archive baselineWorkspaces=\(baseline.workspaces) " +
                "baselinePanels=\(baseline.panels)"
        )
#endif
    }

    /// Returns `snapshot` when this launch may write it to the primary file,
    /// or nil while the overwrite guard holds a poorer, unchanged, young
    /// session back. Removals (nil snapshots) pass through unchanged.
    func snapshotAllowedByOverwriteGuard(
        _ snapshot: AppSessionSnapshot?,
        now: Date = Date()
    ) -> AppSessionSnapshot? {
        guard let snapshot, var overwriteGuard = sessionSnapshotOverwriteGuard else { return snapshot }
        defer { sessionSnapshotOverwriteGuard = overwriteGuard }
        switch overwriteGuard.evaluate(
            candidate: snapshot.richness,
            structure: snapshot.structureSignature,
            now: now
        ) {
        case .write:
            return snapshot
        case .hold:
#if DEBUG
            cmuxDebugLog(
                "session.save.held reason=poorer_young_launch " +
                    "panels=\(snapshot.richness.panels) baselinePanels=\(overwriteGuard.baseline.panels)"
            )
#endif
            return nil
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
