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

    /// Whether stopping the eligible groups can resolve this warning.
    /// Protected runaways must not cause unrelated bystander jobs to be stopped.
    /// - Parameters:
    ///   - ttyDevice: Controlling TTY of the warned terminal.
    ///   - census: Complete process census used for the stop decision.
    ///   - groups: Process groups whose ownership has been validated.
    public func canResolve(ttyDevice: Int64, in census: RunawaySessionCensus, stopping groups: Set<Int>) -> Bool {
        guard !groups.isEmpty, let current = census.usage(ttyDevice: ttyDevice), !hasCleared(current) else { return false }
        guard let remaining = census.usage(ttyDevice: ttyDevice, excludingProcessGroupIDs: groups) else { return true }
        return hasCleared(remaining)
    }
}
