public import Foundation

/// Computes bounded exponential retry delays with a server-provided floor.
public struct CmxIrohRetrySchedule: Equatable, Sendable {
    /// The first retry delay before jitter.
    public let initialDelay: TimeInterval

    /// The largest accepted delay, including a validated `Retry-After` floor.
    public let maximumDelay: TimeInterval

    /// The positive jitter fraction applied above the retry floor.
    public let jitterFraction: Double

    /// Creates a bounded exponential retry schedule.
    ///
    /// - Parameters:
    ///   - initialDelay: The first retry delay before jitter.
    ///   - maximumDelay: The hard delay cap.
    ///   - jitterFraction: The maximum positive jitter as a fraction of the floor.
    public init(
        initialDelay: TimeInterval = 30,
        maximumDelay: TimeInterval = 3_600,
        jitterFraction: Double = 0.25
    ) {
        let normalizedMaximumDelay = max(1, maximumDelay)
        self.initialDelay = min(normalizedMaximumDelay, max(1, initialDelay))
        self.maximumDelay = normalizedMaximumDelay
        self.jitterFraction = min(1, max(0, jitterFraction))
    }

    /// Returns a retry delay that never precedes a server-provided floor.
    ///
    /// - Parameters:
    ///   - failureCount: Zero-based consecutive failure count.
    ///   - retryAfterSeconds: A validated server retry floor, when available.
    ///   - jitterUnitInterval: A deterministic value from zero through one.
    /// - Returns: A positive delay bounded by ``maximumDelay``.
    public func delay(
        failureCount: Int,
        retryAfterSeconds: Int?,
        jitterUnitInterval: Double
    ) -> TimeInterval {
        let boundedFailureCount = min(max(0, failureCount), 20)
        let exponential = initialDelay * pow(2, Double(boundedFailureCount))
        let base = min(maximumDelay, exponential)
        let serverFloor = retryAfterSeconds.map(TimeInterval.init) ?? 0
        let floor = min(maximumDelay, max(base, serverFloor))
        let jitter = min(1, max(0, jitterUnitInterval))
        let available = max(0, maximumDelay - floor)
        let jitterWindow = min(available, floor * jitterFraction)
        return floor + jitterWindow * jitter
    }
}
