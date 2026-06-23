public import Foundation
public import Observation
#if DEBUG
internal import CMUXDebugLog
#endif

/// `@MainActor @Observable` orchestrator for app session persistence and
/// restore.
///
/// Owns the gating state and sequencing that used to live as scattered stored
/// properties + private methods on `AppDelegate`:
///
/// - startup-snapshot preparation latch + the loaded `startupSessionSnapshot`,
/// - the startup-restore latch (`didAttemptStartupSessionRestore`) and the
///   in-progress-restore flag (`isApplyingSessionRestore`),
/// - the process-detected save generation counter (stale-scan guard),
/// - the autosave fingerprint-skip state (`lastSessionAutosaveFingerprint` /
///   `lastSessionAutosavePersistedAt`).
///
/// Every app-coupled effect (build the snapshot from the live window tree, read
/// the fingerprint, persist, apply a window snapshot, load resume indexes,
/// evaluate the decision policy) inverts back through ``AppSessionHosting``.
/// The coordinator does no I/O and reads no AppKit state itself; it sequences
/// the host's witnesses, exactly as the legacy private methods sequenced the
/// in-file bodies. The decision policy lives in
/// ``CmuxWorkspaces/SessionPersistenceDecisionPolicy`` (the host forwards to
/// its shared instance), and the autosave cadence lives in
/// ``CmuxWorkspaces/SessionAutosaveScheduler`` (which calls
/// ``performScheduledAutosave(source:)`` back through its own seam).
///
/// **Isolation.** `@MainActor`: every legacy body it absorbed already ran on
/// the main actor (window/tab/sidebar reads, the `@MainActor` save methods, the
/// autosave `Task { @MainActor in }`), so co-locating the gating state on the
/// main actor turns the cross-object hops into plain calls. No background
/// mutation of this state existed; only pure helpers would be `nonisolated`,
/// and there are none here.
@MainActor
@Observable
public final class AppSessionCoordinator<Host: AppSessionHosting>: SessionRestoring {
    /// The app host the coordinator inverts every effect back through. Weak so
    /// the coordinator (retained by the host) does not pin the host (which
    /// would keep the app-host test instance alive), mirroring the existing
    /// weak-owner adapters in the app target.
    private weak var host: Host?

    /// The startup snapshot loaded by ``prepareStartupSnapshotIfNeeded()`` and
    /// consumed by ``attemptStartupRestoreIfNeeded()``. Cleared once restore
    /// completes.
    public private(set) var startupSessionSnapshot: Host.Snapshot?

    private var didPrepareStartupSessionSnapshot = false

    /// Whether the startup-restore attempt has already run for this launch.
    /// Public + settable because the app's deferred-bootstrap path latches it
    /// directly when it decides to skip restore (matching the legacy
    /// `didAttemptStartupSessionRestore = true` writes outside the restore body).
    public var didAttemptStartupSessionRestore = false

    /// Whether a startup or manual restore is currently being applied. Live
    /// saves are suppressed while true.
    public private(set) var isApplyingSessionRestore = false

    private var processDetectedSessionSaveGeneration: UInt64 = 0
    private var lastSessionAutosaveFingerprint: Int?
    private var lastSessionAutosavePersistedAt: Date = .distantPast

    /// Creates the coordinator. Call ``attach(host:)`` at the composition root
    /// to wire the app host (kept separate from `init` so the host can build
    /// the coordinator inside its own `lazy` initializer and then attach
    /// itself, the established weak-owner attach pattern).
    public init() {}

    /// Attaches the app host. Idempotent-safe (last write wins); the host
    /// attaches itself once during composition.
    public func attach(host: Host) {
        self.host = host
    }

    // MARK: - Startup preparation

    public func prepareStartupSnapshotIfNeeded() {
        guard !didPrepareStartupSessionSnapshot else { return }
        didPrepareStartupSessionSnapshot = true
        guard let host else { return }
        host.removeLegacyWindowGeometry()
        host.syncManualRestoreSnapshotCache()
        guard host.shouldAttemptStartupRestore() else { return }
        startupSessionSnapshot = host.loadStartupSnapshot()
    }

    // MARK: - Startup restore

    @discardableResult
    public func attemptStartupRestoreIfNeeded() -> Bool {
        guard !didAttemptStartupSessionRestore else { return false }
        didAttemptStartupSessionRestore = true
        guard let host else { return false }
        guard let snapshot = startupSessionSnapshot else {
            // No snapshot: the host applies its persisted-geometry fallback and
            // completes the restore itself (nothing to enqueue).
            host.applyStartupRestoreFallbackGeometry()
            return false
        }
        isApplyingSessionRestore = true
        let didApply = host.applyStartupRestore(snapshot: snapshot)
        // The host enqueues additional windows and calls
        // `completeRestore(isManualReopen:)` back when its window application
        // (possibly deferred to the next main-loop turn) finishes.
        return didApply
    }

    /// Called back by the host once startup or manual restore finishes applying
    /// its windows. Clears the startup snapshot, lowers the in-progress flag,
    /// and triggers the post-restore save when the policy allows it.
    public func completeRestore(isManualReopen: Bool) {
        startupSessionSnapshot = nil
        isApplyingSessionRestore = false
        guard let host else { return }
        if host.shouldSaveSessionSnapshotOnRestoreCompletion(isManualReopen: isManualReopen) {
            // Auto-resume input can be queued before tmux has spawned; preserve
            // restored process-detected bindings until a later live scan. Routes
            // through the gated `saveSessionSnapshot` so the restore-skip check
            // matches the legacy `completeSessionRestoreOperation` path.
            _ = saveSessionSnapshot(includeScrollback: false)
        }
    }

    /// Discards the loaded startup snapshot and latches the restore attempt when
    /// an explicit open intent (deep link / service open / file open) arrives
    /// before startup restore has run. Mirrors the legacy
    /// `AppDelegate.prepareForExplicitOpenIntentAtStartup` body's
    /// `startupSessionSnapshot = nil; didAttemptStartupSessionRestore = true`
    /// writes, which now own this gating state here.
    public func discardStartupSnapshotForExplicitOpenIntent() {
        guard !didAttemptStartupSessionRestore else { return }
        startupSessionSnapshot = nil
        didAttemptStartupSessionRestore = true
    }

    // MARK: - Manual reopen

    @discardableResult
    public func reopenPreviousSession(shouldActivate: Bool = true) -> Bool {
        guard let host, let snapshot = host.loadReopenSessionSnapshot() else {
            return false
        }
        return restorePreviousSessionSnapshot(snapshot, shouldActivate: shouldActivate)
    }

    @discardableResult
    public func restorePreviousSessionSnapshot(
        _ snapshot: Host.Snapshot,
        shouldActivate: Bool = true
    ) -> Bool {
        guard let host else { return false }
        isApplyingSessionRestore = true
        startupSessionSnapshot = nil
        didAttemptStartupSessionRestore = true
        let didCreate = host.applyManualRestore(snapshot: snapshot, shouldActivate: shouldActivate)
        return didCreate
    }

    // MARK: - Save

    /// Mirrors the legacy `saveSessionSnapshot` gating: it suppresses the save
    /// during an in-progress restore, then delegates the actual build + persist
    /// to the host (which still owns the live-tree read and the persistor
    /// call). The host returns whether a snapshot was written.
    @discardableResult
    public func saveSessionSnapshot(
        includeScrollback: Bool,
        removeWhenEmpty: Bool = false,
        restorableAgentIndex: AppSessionResumeIndexes? = nil
    ) -> Bool {
        guard let host else { return false }
        if host.shouldSkipSessionSaveDuringRestore(includeScrollback: includeScrollback) {
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "session.save.skipped reason=session_restore_in_progress includeScrollback=0"
            )
#endif
            return false
        }
        return host.saveSessionSnapshot(
            includeScrollback: includeScrollback,
            removeWhenEmpty: removeWhenEmpty,
            restorableAgentIndex: restorableAgentIndex
        )
    }

    /// Synchronously saves after loading the process-detected resume indexes
    /// inline (the termination / explicit-save path). Mirrors the legacy
    /// `saveSessionSnapshotIncludingProcessDetectedIndexes`.
    @discardableResult
    public func saveSessionSnapshotIncludingProcessDetectedIndexes(
        includeScrollback: Bool,
        removeWhenEmpty: Bool = false
    ) -> Bool {
        guard let host else { return false }
        let indexes = host.loadProcessDetectedResumeIndexesSynchronously()
        return saveSessionSnapshot(
            includeScrollback: includeScrollback,
            removeWhenEmpty: removeWhenEmpty,
            restorableAgentIndex: indexes
        )
    }

    /// Loads the process-detected resume indexes asynchronously, then saves
    /// (guarding against a stale scan and termination). Mirrors the legacy
    /// `saveSessionSnapshotAfterLoadingProcessDetectedIndexes`.
    public func saveSessionSnapshotAfterLoadingProcessDetectedIndexes(
        includeScrollback: Bool,
        removeWhenEmpty: Bool = false
    ) {
        let generation = nextProcessDetectedSessionSaveGeneration()
        Task { @MainActor [weak self] in
            guard let self, let host = self.host else { return }
            let indexes = await host.loadProcessDetectedResumeIndexes()
            guard !host.isTerminatingApp,
                  self.isCurrentProcessDetectedSessionSaveGeneration(generation) else { return }
            _ = self.saveSessionSnapshot(
                includeScrollback: includeScrollback,
                removeWhenEmpty: removeWhenEmpty,
                restorableAgentIndex: indexes
            )
        }
    }

    // MARK: - Scheduled autosave (CmuxWorkspaces SessionAutosaveScheduler seam)

    /// Performs one scheduled session-snapshot autosave. Lifted verbatim from
    /// the legacy `AppDelegate.performScheduledAutosave(source:)` body (the
    /// scheduler already owns the latch + typing-quiet deferral): allocate a
    /// process-detected scan generation, load the resume indexes, guard against
    /// a stale scan, apply the unchanged-fingerprint skip, write the snapshot,
    /// record the new autosave state.
    public func performScheduledAutosave(source: String) async {
        guard let host else { return }
        let generation = nextProcessDetectedSessionSaveGeneration()
        let now = Date()
        let indexes = await host.loadProcessDetectedResumeIndexes()
        guard !host.isTerminatingApp,
              isCurrentProcessDetectedSessionSaveGeneration(generation) else {
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "session.save.skipped reason=stale_process_detected_scan includeScrollback=0 source=\(source)"
            )
#endif
            return
        }
        let autosaveFingerprint = host.sessionAutosaveFingerprint(
            includeScrollback: false,
            restorableAgentIndex: indexes
        )
        if host.shouldSkipSessionAutosaveForUnchangedFingerprint(
            includeScrollback: false,
            previousFingerprint: lastSessionAutosaveFingerprint,
            currentFingerprint: autosaveFingerprint,
            lastPersistedAt: lastSessionAutosavePersistedAt,
            now: now
        ) {
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "session.save.skipped reason=unchanged_autosave_fingerprint includeScrollback=0 source=\(source)"
            )
#endif
            return
        }
        _ = saveSessionSnapshot(
            includeScrollback: false,
            removeWhenEmpty: false,
            restorableAgentIndex: indexes
        )
        updateSessionAutosaveSaveState(
            includeScrollback: false,
            persistedAt: now,
            fingerprint: autosaveFingerprint
        )
    }

    private func updateSessionAutosaveSaveState(
        includeScrollback: Bool,
        persistedAt: Date,
        fingerprint: Int?
    ) {
        guard let host, !host.isTerminatingApp, !includeScrollback else { return }
        lastSessionAutosaveFingerprint = fingerprint
        lastSessionAutosavePersistedAt = persistedAt
    }

    // MARK: - Process-detected scan generation

    @discardableResult
    private func nextProcessDetectedSessionSaveGeneration() -> UInt64 {
        processDetectedSessionSaveGeneration &+= 1
        return processDetectedSessionSaveGeneration
    }

    private func isCurrentProcessDetectedSessionSaveGeneration(_ generation: UInt64) -> Bool {
        generation == processDetectedSessionSaveGeneration
    }
}
