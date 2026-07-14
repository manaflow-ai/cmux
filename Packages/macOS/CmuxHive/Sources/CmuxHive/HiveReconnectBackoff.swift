import Foundation

/// Shared bounded reconnect backoff for hive sessions: 1s doubling to 30s.
///
/// A genuine, cancellable delay (not a poll): each awaited attempt is a real
/// reconnect, and cancelling the owning task cancels the pending sleep.
public enum HiveReconnectBackoff {
    /// Await the backoff for the given consecutive-failure attempt count.
    public static func delay(attempt: Int) async {
        let seconds = min(30.0, pow(2.0, Double(min(max(attempt - 1, 0), 5))))
        // Bounded, cancellable delay — the intended behavior, per the
        // Clock.sleep carve-out.
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
