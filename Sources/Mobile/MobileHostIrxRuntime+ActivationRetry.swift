import CmuxIrohTransport
import Foundation

extension MobileHostIrxRuntime {
    /// Longest wait between two activation attempts on the doubling ladder.
    nonisolated static let maximumActivationRetryDelay: TimeInterval = 5 * 60

    /// Delay before the next activation attempt after `error`.
    ///
    /// The ladder starts at 5 s and doubles per consecutive failure up to
    /// `maximumActivationRetryDelay`. A broker `Retry-After` is a floor that
    /// wins over the ladder, and `jitterUnitInterval` (0...1) adds up to a
    /// quarter of the resulting delay so a fleet told to wait the same window
    /// does not re-mint in lockstep.
    nonisolated static func activationRetryDelay(
        after error: any Error,
        failureCount: Int,
        jitterUnitInterval: Double
    ) -> TimeInterval {
        let exponent = min(max(failureCount, 0), 16)
        let ladder = min(5 * pow(2, Double(exponent)), maximumActivationRetryDelay)
        let serverFloor = TimeInterval(
            max(0, (error as? any CmxRetryAfterProviding)?.retryAfterSeconds ?? 0)
        )
        let base = max(ladder, serverFloor)
        let jitter = min(max(jitterUnitInterval, 0), 1) * base * 0.25
        return base + jitter
    }

}
