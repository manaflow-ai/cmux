import Foundation

/// Injectable clock behind `TabManager`'s deferred selection side-effects: the
/// near-zero yield that lets the synchronous `selectedWorkspaceIdDidChange`
/// turn finish before `focusSelectedWorkspacePanel` /
/// `updateWindowTitleForSelectedTab` /
/// `dismissFocusedPanelNotificationIfActive` run.
///
/// Replaces the banned `DispatchQueue.main.async` deferral with a cancellable
/// `Clock` task whose cancellation is wired to the selection generation latch
/// (the next selection bumps `selectionSideEffectsGeneration`, which cancels the
/// prior task). A seam (mirroring `GitPollClock`/`UpdateClock`) so tests can
/// drive the deferral with virtual time instead of a real main-queue hop.
///
/// The seam lives app-side next to `TabManager`, which owns the deferred body
/// (focused-surface, focus-history, notification-dismissal, window-title) and
/// the generation state it guards on, per the "clock lives with the code that
/// sleeps" ruling.
protocol TabManagerSelectionSideEffectsClock: Sendable {
    /// Suspends for `duration`, throwing `CancellationError` when the owning
    /// task is cancelled first (the next selection's generation bump cancels the
    /// prior deferred task during this wait).
    func sleep(for duration: Duration) async throws
}

/// The production ``TabManagerSelectionSideEffectsClock``, backed by
/// `Task.sleep`.
struct SystemTabManagerSelectionSideEffectsClock: TabManagerSelectionSideEffectsClock {
    /// Creates the production clock.
    init() {}

    /// Suspends for `duration` on the system clock.
    func sleep(for duration: Duration) async throws {
        // Bounded, cancellable, intended deferral behind the injected clock seam
        // (modern-concurrency carve-out): a near-zero yield matching the legacy
        // `DispatchQueue.main.async` deferral, cancelled with the owning task
        // wherever the previous deferred block was superseded by a generation
        // bump.
        try await Task.sleep(for: duration)
    }
}
