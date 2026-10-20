/// The production ``GitPollClock``, backed by `Task.sleep`.
public struct SystemGitPollClock: GitPollClock {
    /// Creates the production clock.
    public init() {}

    /// Suspends for `duration` on the system clock.
    public func sleep(for duration: Duration) async throws {
        // Bounded, cancellable, intended delays/deadlines behind the injected
        // clock seam (modern-concurrency carve-out): probe retry gaps and poll
        // deadlines, cancelled with the owning task wherever the previous
        // DispatchSourceTimers were cancelled.
        try await Task.sleep(for: duration)
    }
}
