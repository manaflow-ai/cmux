/// Injectable clock behind the subrouter poll deadlines, mirroring
/// `GitPollClock`: tests drive the schedule with virtual time instead of
/// real waits.
public protocol SubrouterPollClock: Sendable {
    /// Suspends for `duration`, throwing `CancellationError` when the owning
    /// task is cancelled first.
    func sleep(for duration: Duration) async throws
}
