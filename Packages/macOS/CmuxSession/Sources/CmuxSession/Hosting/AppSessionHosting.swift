public import CmuxWorkspaces
public import Foundation

/// Host seam through which ``AppSessionCoordinator`` drives the app-coupled
/// half of session persistence and restore.
///
/// The coordinator owns the gating state and sequencing (startup prepare,
/// startup-restore gating, the autosave fingerprint-skip decision, the
/// process-detected scan generation, the manual reopen flow). Everything that
/// reads the live window/tab/sidebar tree or mutates an `NSWindow` is
/// irreducibly app-coupled and inverts back here: `AppDelegate` conforms and
/// the coordinator calls back into it on the main actor. This is the
/// executable-target inversion required by the refactor's
/// section-6 boundary (stored window/tab/sidebar state cannot cross the module
/// boundary, so the coordinator reads it through these witnesses instead).
///
/// **Associated types are bounded by the EXISTING CmuxWorkspaces seams.** The
/// snapshot root conforms to ``CmuxWorkspaces/SessionSnapshotRepresenting`` and
/// the geometry payload to ``CmuxWorkspaces/WindowGeometryPersisting`` (the
/// app's `AppSessionSnapshot` and `AppDelegate.PersistedWindowGeometry` already
/// conform to those). The coordinator therefore never names the concrete wire
/// types; it speaks only the two CmuxWorkspaces protocols and the host's
/// associated types, so the on-disk format stays owned by the app target.
@MainActor
public protocol AppSessionHosting: AnyObject {
    /// The app-owned session snapshot root (conforms to the CmuxWorkspaces
    /// ``SessionSnapshotRepresenting`` seam).
    associatedtype Snapshot: SessionSnapshotRepresenting
    /// The app-owned persisted-window-geometry payload (conforms to the
    /// CmuxWorkspaces ``WindowGeometryPersisting`` seam).
    associatedtype GeometryPayload: WindowGeometryPersisting

    // MARK: Termination

    /// Whether the app is shutting down. Read on the autosave tick and in the
    /// process-detected scan guards, exactly as the legacy
    /// `isTerminatingApp` reads did.
    var isTerminatingApp: Bool { get }

    // MARK: Startup snapshot preparation

    /// Whether `SessionRestorePolicy.shouldAttemptRestore()` is satisfied for
    /// this launch (no explicit open intent, not under automated tests, restore
    /// not disabled). The host evaluates the policy against `CommandLine`/the
    /// process environment.
    func shouldAttemptStartupRestore() -> Bool

    /// Clears the legacy primary-window-geometry defaults keys
    /// (`WindowGeometryStore.removeLegacy`).
    func removeLegacyWindowGeometry()

    /// Mirrors the primary snapshot into the manual-restore backup
    /// (`SessionSnapshotStoring.syncManualRestoreSnapshotCache`).
    func syncManualRestoreSnapshotCache()

    /// Loads the usable startup snapshot (primary when usable, else the
    /// manual-restore backup), or nil.
    func loadStartupSnapshot() -> Snapshot?

    // MARK: Snapshot build + persist

    /// Builds the live session snapshot from the registered windows, or nil
    /// when there is nothing to persist. `restorableAgentIndex` /
    /// `surfaceResumeBindingIndex` are opaque app-side index values; the host
    /// forwards them to its `TabManager.sessionSnapshot` reads.
    func buildSessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: AppSessionResumeIndexes?
    ) -> Snapshot?

    /// Encodes the primary-window geometry payload for `snapshot`'s first
    /// window, or nil when there is no window/frame. Used so the geometry write
    /// rides the same persist call as the snapshot write.
    func encodedPrimaryWindowGeometryData(for snapshot: Snapshot) -> Data?

    /// Persists `snapshot` (and the already-encoded primary-window geometry)
    /// through the app-owned ``CmuxWorkspaces/SessionSnapshotPersistor``.
    /// `synchronously` runs the write inline (termination path); otherwise the
    /// persistor queues it.
    func persist(
        snapshot: Snapshot?,
        removeWhenEmpty: Bool,
        persistedGeometryData: Data?,
        synchronously: Bool
    )

    // MARK: Save decision policy (forwards to the CmuxWorkspaces policy)

    /// Whether a save must be written inline on the caller's thread (the
    /// terminating scrollback save), via
    /// ``CmuxWorkspaces/SessionPersistenceDecisionPolicy``.
    func shouldWriteSessionSnapshotSynchronously(includeScrollback: Bool) -> Bool

    /// Whether the in-progress restore should suppress this save, via the
    /// decision policy.
    func shouldSkipSessionSaveDuringRestore(includeScrollback: Bool) -> Bool

    /// Whether the unchanged-fingerprint autosave skip applies, via the
    /// decision policy. The coordinator passes its tracked previous fingerprint
    /// + persisted-at; the host folds them through the policy.
    func shouldSkipSessionAutosaveForUnchangedFingerprint(
        includeScrollback: Bool,
        previousFingerprint: Int?,
        currentFingerprint: Int?,
        lastPersistedAt: Date,
        now: Date
    ) -> Bool

    /// Whether a save should run after restore completion / main-window
    /// registration / application resign, via the decision policy.
    func shouldSaveSessionSnapshotOnRestoreCompletion(isManualReopen: Bool) -> Bool

    // MARK: Autosave fingerprint

    /// Computes the autosave fingerprint over the live window/tab/sidebar tree
    /// for the given resume indexes, or nil when `includeScrollback` is true.
    func sessionAutosaveFingerprint(
        includeScrollback: Bool,
        restorableAgentIndex: AppSessionResumeIndexes
    ) -> Int?

    /// Performs the actual snapshot save for the given resume indexes,
    /// returning whether a snapshot was written. Wraps the host's
    /// `saveSessionSnapshot` body (snapshot build + geometry encode + persist).
    @discardableResult
    func saveSessionSnapshot(
        includeScrollback: Bool,
        removeWhenEmpty: Bool,
        restorableAgentIndex: AppSessionResumeIndexes?
    ) -> Bool

    // MARK: Process-detected resume indexes

    /// Loads the process-detected resume indexes asynchronously (the autosave
    /// tick path), wrapping `ProcessDetectedResumeIndexes.load()`.
    func loadProcessDetectedResumeIndexes() async -> AppSessionResumeIndexes

    /// Loads the process-detected resume indexes synchronously (the
    /// termination / explicit-save path), wrapping
    /// `ProcessDetectedResumeIndexes.loadSynchronously()`.
    func loadProcessDetectedResumeIndexesSynchronously() -> AppSessionResumeIndexes

    // MARK: Restore application

    /// Applies the primary window snapshot to the primary registered window and
    /// enqueues any additional windows, returning whether a primary snapshot
    /// was present. Wraps the legacy
    /// `attemptStartupSessionRestoreIfNeeded` body's window-application tail.
    /// The host calls ``AppSessionCoordinator/completeRestore(isManualReopen:)``
    /// back when its (possibly deferred) window application finishes.
    func applyStartupRestore(snapshot: Snapshot) -> Bool

    /// Runs the no-startup-snapshot fallback: resolves the persisted
    /// primary-window geometry against the live displays and sets the primary
    /// window frame. Wraps the `else` branch of the legacy
    /// `attemptStartupSessionRestoreIfNeeded` body. The host completes the
    /// restore itself (there is nothing to enqueue).
    func applyStartupRestoreFallbackGeometry()

    /// Creates the windows for a manual reopen / restore-previous-session
    /// snapshot and optionally activates the primary, returning whether any
    /// window was created. Wraps the legacy
    /// `restorePreviousSessionSnapshot` body.
    func applyManualRestore(snapshot: Snapshot, shouldActivate: Bool) -> Bool

    /// Loads the manual-restore ("Reopen Previous Session") snapshot, or nil.
    func loadReopenSessionSnapshot() -> Snapshot?
}
