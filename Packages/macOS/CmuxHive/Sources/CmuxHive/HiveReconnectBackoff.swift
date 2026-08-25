import Foundation

/// Bounded exponential reconnect backoff for hive sessions: 1s doubling to a
/// configurable cap.
///
/// A genuine, cancellable delay (not a poll): each awaited attempt is a real
/// reconnect, and cancelling the owning task cancels the pending sleep.
public struct HiveReconnectBackoff: Sendable {
    /// The longest single delay, in seconds.
    public var maximumSeconds: Double

    /// Creates a backoff capped at `maximumSeconds`.
    public init(maximumSeconds: Double = 30) {
        self.maximumSeconds = maximumSeconds
    }

    /// Await the backoff for the given consecutive-failure attempt count.
    @concurrent
    public func delay(attempt: Int) async {
        let seconds = min(maximumSeconds, pow(2.0, Double(min(max(attempt - 1, 0), 6))))
        // This is a bounded retry delay, not a state-settling sleep. The
        // continuous clock observes task cancellation without blocking a
        // thread or inheriting the caller's actor.
        do {
            try await ContinuousClock().sleep(for: .seconds(seconds))
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }
}
