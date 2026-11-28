import Foundation

/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum PhonePushRetryPolicy: Sendable {
    public static let maximumAttempts = 3

    public static func delaySeconds(
        afterAttempt: Int,
        result: PhonePushHTTPResult,
        retryAfterSeconds: Int?,
        nowEpochSeconds: Int,
        expirationEpochSeconds: Int
    ) -> Int? {
        guard result.shouldRetry,
              afterAttempt > 0,
              afterAttempt < maximumAttempts else { return nil }
        let fallback = afterAttempt == 1 ? 1 : 2
        // Retry-After is the provider's lower bound, not a suggestion that the
        // client may shorten. The event TTL remains the upper bound: if the
        // requested delay would make this event stale, expire it instead.
        let delay = max(fallback, retryAfterSeconds ?? 0)
        let (retryEpochSeconds, overflowed) = nowEpochSeconds
            .addingReportingOverflow(delay)
        guard !overflowed, retryEpochSeconds < expirationEpochSeconds else {
            return nil
        }
        return delay
    }
}
