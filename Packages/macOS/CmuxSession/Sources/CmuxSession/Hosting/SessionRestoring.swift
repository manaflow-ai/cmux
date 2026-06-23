/// Restore-direction surface ``AppSessionCoordinator`` exposes to the app.
///
/// The app target's menu / CLI "Reopen Previous Session" entrypoints and the
/// startup-window bootstrap call these instead of reaching into the gating
/// state directly. Keeping them on a protocol lets the menu/CLI callers depend
/// on the abstraction and lets tests drive restore without the live window
/// tree. The coordinator is the sole production conformer.
@MainActor
public protocol SessionRestoring: AnyObject {
    /// Prepares the startup snapshot once: clears legacy geometry keys, syncs
    /// the manual-restore backup, and loads the startup snapshot when restore
    /// is allowed for this launch. Idempotent (guarded by an internal latch).
    func prepareStartupSnapshotIfNeeded()

    /// Attempts the one-shot startup session restore against the primary
    /// window. Returns whether a restore was applied. Idempotent (guarded by
    /// the startup-restore latch).
    @discardableResult
    func attemptStartupRestoreIfNeeded() -> Bool

    /// Reopens the previous session from the manual-restore backup snapshot.
    /// Returns whether a session was restored.
    @discardableResult
    func reopenPreviousSession(shouldActivate: Bool) -> Bool

    /// Whether a startup restore is currently being applied. Live saves are
    /// suppressed while true (matching the legacy `isApplyingSessionRestore`).
    var isApplyingSessionRestore: Bool { get }

    /// Whether the startup-restore attempt has already run for this launch.
    var didAttemptStartupSessionRestore: Bool { get set }
}
