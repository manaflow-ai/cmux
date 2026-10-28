/// When a terminal session counts as running away, for the user warning.
public struct RunawaySessionWarningPolicy: Equatable, Sendable {
    /// Session memory at or above which the user is warned.
    public let memoryThresholdBytes: Int64
    /// Session process count at or above which the user is warned.
    public let processCountThreshold: Int
    /// Fraction of both thresholds a warned session must fall below to clear.
    public let clearFraction: Double

    /// Creates a policy.
    public init(
        memoryThresholdBytes: Int64,
        processCountThreshold: Int = 1_000,
        clearFraction: Double = 0.8
    ) {
        self.memoryThresholdBytes = max(1, memoryThresholdBytes)
        self.processCountThreshold = max(1, processCountThreshold)
        self.clearFraction = min(max(clearFraction, 0), 1)
    }

    /// Whether the session crossed either threshold.
    public func isRunaway(_ usage: RunawaySessionUsage) -> Bool {
        usage.memoryBytes >= memoryThresholdBytes || usage.processCount >= processCountThreshold
    }

    /// Whether a warned session fell below the clear level on both measures.
    public func hasCleared(_ usage: RunawaySessionUsage) -> Bool {
        usage.memoryIsComplete && Double(usage.memoryBytes) < Double(memoryThresholdBytes) * clearFraction &&
            Double(usage.processCount) < Double(processCountThreshold) * clearFraction
    }
}
