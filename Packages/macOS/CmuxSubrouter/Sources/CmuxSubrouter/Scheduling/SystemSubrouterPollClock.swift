/// The production ``SubrouterPollClock``, backed by `Task.sleep`.
public struct SystemSubrouterPollClock: SubrouterPollClock {
    /// Creates the production clock.
    public init() {}

    /// Suspends for `duration` on the system clock.
    public func sleep(for duration: Duration) async throws {
        // Bounded, cancellable, intended poll deadlines behind the injected
        // clock seam (modern-concurrency carve-out); re-arming cancels the
        // owning task.
        try await Task.sleep(for: duration)
    }
}
