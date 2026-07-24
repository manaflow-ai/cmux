/// Injectable clock behind the sidebar git/PR polling delays: the initial
/// probe retry gaps, the metadata fallback loop, and the pull-request poll
/// deadline. A seam (mirroring `FileWatchClock`/`UpdateClock`) so tests can
/// drive these schedules with virtual time instead of real waits.
///
/// The clock lives in this package, next to the scheduling code that sleeps
/// on it, per the "clock lives with the code that sleeps" ruling.
public protocol GitPollClock: Sendable {
    /// Suspends for `duration`, throwing `CancellationError` when the owning
    /// task is cancelled first.
    func sleep(for duration: Duration) async throws
}
