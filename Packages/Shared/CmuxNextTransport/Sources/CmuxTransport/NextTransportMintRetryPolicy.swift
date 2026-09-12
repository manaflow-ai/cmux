import Foundation

/// Mint-failure backoff: halve the remaining validity per retry (never a
/// hot loop — 10 s floor), and once past expiry keep trying at a bounded
/// cadence. A failed mint never tears the endpoint down.
public struct NextTransportMintRetryPolicy: Sendable {
    let minimumDelaySeconds: Int64
    let expiredCadenceSeconds: Int64

    /// Creates a bounded retry policy for failed credential mints.
    ///
    /// - Parameters:
    ///   - minimumDelaySeconds: Minimum retry delay before credential expiry.
    ///   - expiredCadenceSeconds: Retry cadence after expiry or with unknown expiry.
    public init(minimumDelaySeconds: Int64 = 10, expiredCadenceSeconds: Int64 = 60) {
        self.minimumDelaySeconds = minimumDelaySeconds
        self.expiredCadenceSeconds = expiredCadenceSeconds
    }

    /// Computes the next retry delay without sleeping or making a network call.
    ///
    /// - Parameters:
    ///   - earliestExpiry: Earliest credential expiry in epoch seconds, if known.
    ///   - now: Current epoch seconds.
    /// - Returns: The bounded delay in seconds.
    public func retryDelay(earliestExpiry: Int64?, now: Int64) -> Int64 {
        guard let earliestExpiry, earliestExpiry > now else {
            return expiredCadenceSeconds
        }
        return max((earliestExpiry - now) / 2, minimumDelaySeconds)
    }
}
