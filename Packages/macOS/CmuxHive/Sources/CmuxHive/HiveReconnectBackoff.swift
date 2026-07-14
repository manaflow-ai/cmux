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
    public func delay(attempt: Int) async {
        let seconds = min(maximumSeconds, pow(2.0, Double(min(max(attempt - 1, 0), 6))))
        // Bounded, cancellable delay — the intended behavior, per the
        // Clock.sleep carve-out.
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
