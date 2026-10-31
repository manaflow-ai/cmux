import Foundation
import CmuxWorkspaces

/// Performs the file-backed portion of startup session preparation away from
/// AppKit's main actor. The result is applied on the main actor before any
/// window bootstrap or session autosave can proceed.
actor StartupSessionSnapshotPreparation {
    typealias Store = any SessionSnapshotStoring<AppSessionSnapshot>

    struct Result: Sendable {
        let startupSnapshot: AppSessionSnapshot?
        let overwriteGuard: SessionSnapshotOverwriteGuard?
        let clearsCrashOnlyPrimarySnapshotRemovalMarker: Bool
    }

    let store: Store
    let previousLaunchWasUnclean: Bool
    let crashOnlyPrimarySnapshotRemovalMarker: Bool
    let shouldAttemptRestore: Bool
    let didHandleExplicitOpenIntent: Bool
    let shouldInstallOverwriteGuard: Bool
    let environment: [String: String]

    init(
        store: Store,
        previousLaunchWasUnclean: Bool,
        crashOnlyPrimarySnapshotRemovalMarker: Bool,
        shouldAttemptRestore: Bool,
        didHandleExplicitOpenIntent: Bool,
        shouldInstallOverwriteGuard: Bool,
        environment: [String: String]
    ) {
        self.store = store
        self.previousLaunchWasUnclean = previousLaunchWasUnclean
        self.crashOnlyPrimarySnapshotRemovalMarker = crashOnlyPrimarySnapshotRemovalMarker
        self.shouldAttemptRestore = shouldAttemptRestore
        self.didHandleExplicitOpenIntent = didHandleExplicitOpenIntent
        self.shouldInstallOverwriteGuard = shouldInstallOverwriteGuard
        self.environment = environment
    }

    func run() -> Result {
        let primaryURL = store.defaultSnapshotFileURL()
        let primaryOutcome = primaryURL.map { store.loadOutcome(fileURL: $0) }
        var overwriteGuard: SessionSnapshotOverwriteGuard?
        if shouldInstallOverwriteGuard {
            overwriteGuard = archiveSnapshot(
                primaryURL: primaryURL,
                primaryOutcome: primaryOutcome,
                now: Date()
            )
        }

        synchronizeManualRestoreCache(
            primaryURL: primaryURL,
            primaryOutcome: primaryOutcome
        )
        let sanitizedSnapshot = loadStartupSnapshot(
            primaryURL: primaryURL,
            primaryOutcome: primaryOutcome,
            overwriteGuard: &overwriteGuard
        )
        prepareScrollbackCheckpoints(primaryURL: primaryURL)

        var startupSnapshot: AppSessionSnapshot?
        if shouldAttemptRestore, !didHandleExplicitOpenIntent {
            if previousLaunchWasUnclean,
               let sanitizedSnapshot,
               let checkpointStore = primaryURL.map({ SessionScrollbackCheckpointStore(primarySnapshotURL: $0) }) {
                startupSnapshot = checkpointStore.merging(into: sanitizedSnapshot)
            } else {
                startupSnapshot = sanitizedSnapshot
            }
        }

        return Result(
            startupSnapshot: startupSnapshot,
            overwriteGuard: overwriteGuard,
            clearsCrashOnlyPrimarySnapshotRemovalMarker: primaryOutcome.map {
                switch $0 {
                case .loaded(_), .unusable: return true
                case .missing: return false
                }
            } ?? false
        )
    }

    private func archiveSnapshot(
        primaryURL: URL?,
        primaryOutcome: SessionSnapshotLoadOutcome<AppSessionSnapshot>?,
        now: Date
    ) -> SessionSnapshotOverwriteGuard {
        var baseline = SessionSnapshotRichness.empty
        let candidates = [
            primaryURL,
            store.manualRestoreSnapshotFileURL()
        ].compactMap { $0 }
        var primaryIsMissing = false
        for fileURL in candidates {
            let outcome = (fileURL == primaryURL ? primaryOutcome : nil)
                ?? store.loadOutcome(fileURL: fileURL)
            if fileURL == primaryURL, case .missing = outcome {
                primaryIsMissing = true
            }
            guard case .loaded(let snapshot) = outcome else { continue }
            if fileURL == primaryURL
                || !primaryIsMissing
                || previousLaunchWasUnclean
                || crashOnlyPrimarySnapshotRemovalMarker {
                baseline = snapshot.richness
            }
            store.archiveSnapshotToHistory(
                fileURL: fileURL,
                richness: snapshot.richness,
                archivedAt: now
            )
            break
        }
        return SessionSnapshotOverwriteGuard(baseline: baseline, launchDate: now)
    }

    private func synchronizeManualRestoreCache(
        primaryURL: URL?,
        primaryOutcome: SessionSnapshotLoadOutcome<AppSessionSnapshot>?
    ) {
        guard let primaryURL,
              let backupURL = store.manualRestoreSnapshotFileURL() else {
            return
        }
        switch primaryOutcome ?? store.loadOutcome(fileURL: primaryURL) {
        case .loaded(let snapshot):
            guard let prunedSnapshot = SessionPersistencePolicy
                .pruningCmuxCrashDiagnosticWindows(from: snapshot)
                .snapshot else {
                return
            }
            if previousLaunchWasUnclean,
               case .loaded = store.loadOutcome(fileURL: backupURL) {
                return
            }
            guard store.preserveNewerSchemaSnapshotBeforeReplacing(fileURL: backupURL) else {
                return
            }
            _ = store.save(prunedSnapshot, fileURL: backupURL)
        case .missing:
            if !previousLaunchWasUnclean,
               !crashOnlyPrimarySnapshotRemovalMarker,
               store.preserveNewerSchemaSnapshotBeforeReplacing(fileURL: backupURL) {
                store.removeSnapshot(fileURL: backupURL)
            }
        case .unusable:
            store.preserveNewerSchemaSnapshot(fileURL: primaryURL)
            store.preserveNewerSchemaSnapshot(fileURL: backupURL)
            store.preserveUnusableSnapshot(fileURL: primaryURL)
            store.preserveUnusableSnapshot(fileURL: backupURL)
        }
    }

    private func loadStartupSnapshot(
        primaryURL: URL?,
        primaryOutcome: SessionSnapshotLoadOutcome<AppSessionSnapshot>?,
        overwriteGuard: inout SessionSnapshotOverwriteGuard?
    ) -> AppSessionSnapshot? {
        guard let primaryURL else { return nil }
        switch primaryOutcome ?? store.loadOutcome(fileURL: primaryURL) {
        case .loaded(let snapshot):
            return SessionPersistencePolicy
                .pruningCmuxCrashDiagnosticWindows(from: snapshot)
                .snapshot ?? loadManualRestoreSnapshot()
        case .missing:
            guard previousLaunchWasUnclean || crashOnlyPrimarySnapshotRemovalMarker
            else {
                return nil
            }
            return loadManualRestoreSnapshot()
        case .unusable:
            if let backup = loadManualRestoreSnapshot() {
                return backup
            }
            guard let recovered = store.newestRestorableHistorySnapshot({
                SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: $0).snapshot
            }) else {
                return nil
            }
            if let currentGuard = overwriteGuard,
               currentGuard.baseline < recovered.richness {
                overwriteGuard = SessionSnapshotOverwriteGuard(
                    baseline: recovered.richness,
                    launchDate: currentGuard.launchDate
                )
            }
            return recovered
        }
    }

    private func loadManualRestoreSnapshot() -> AppSessionSnapshot? {
        store.loadReopenSessionSnapshot(fileURL: nil).flatMap {
            SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: $0).snapshot
        }
    }

    private func prepareScrollbackCheckpoints(primaryURL: URL?) {
        guard !SessionRestorePolicy.isRunningUnderAutomatedTests(environment: environment),
              environment["CMUX_DISABLE_SESSION_RESTORE"] == "1" || !previousLaunchWasUnclean,
              let primaryURL else {
            return
        }
        SessionScrollbackCheckpointStore(primarySnapshotURL: primaryURL)
            .prepareForLaunch(previousLaunchWasUnclean: false)
    }
}
