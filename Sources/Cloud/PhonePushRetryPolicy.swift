import Foundation

enum PhonePushRetryPolicy {
    static let maximumAttempts = 3

    static func delaySeconds(
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
        let delay = max(retryAfterSeconds ?? fallback, 0)
        let (retryEpochSeconds, overflowed) = nowEpochSeconds
            .addingReportingOverflow(delay)
        guard !overflowed, retryEpochSeconds < expirationEpochSeconds else {
            return nil
        }
        return delay
    }
}
