import Foundation

/// Injectable clock behind `TabManager`'s git/PR polling delays: the initial
/// probe retry gaps, the metadata fallback loop, and the pull-request poll
/// deadline. A seam (mirroring `FileWatchClock`/`UpdateClock`) so tests can
/// drive these schedules with virtual time instead of real waits.
protocol GitPollClock: Sendable {
    /// Suspends for `duration`, throwing `CancellationError` when the owning
    /// task is cancelled first.
    func sleep(for duration: Duration) async throws
}

/// The production ``GitPollClock``, backed by `Task.sleep`.
struct SystemGitPollClock: GitPollClock {
    func sleep(for duration: Duration) async throws {
        // Bounded, cancellable, intended delays/deadlines behind the injected
        // clock seam (modern-concurrency carve-out): probe retry gaps and poll
        // deadlines, cancelled with the owning task wherever the previous
        // DispatchSourceTimers were cancelled.
        try await Task.sleep(for: duration)
    }
}
