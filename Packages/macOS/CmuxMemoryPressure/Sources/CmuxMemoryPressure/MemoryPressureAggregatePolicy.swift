/// Relative aggregate-memory policy shared by production and injectable tests.
public struct MemoryPressureAggregatePolicy: Equatable, Sendable {
    /// Fraction of installed RAM that produces warning severity.
    public let warningCoalitionFraction: Double
    /// Fraction of installed RAM that produces critical severity.
    public let criticalCoalitionFraction: Double
    /// Available-memory fraction used as corroborating warning evidence.
    public let warningAvailableFraction: Double
    /// Available-memory fraction used as corroborating critical evidence.
    public let criticalAvailableFraction: Double

    /// Creates a policy with bounded relative thresholds.
    public init(
        warningCoalitionFraction: Double = 0.50,
        criticalCoalitionFraction: Double = 0.70,
        warningAvailableFraction: Double = 0.20,
        criticalAvailableFraction: Double = 0.10
    ) {
        let warning = Self.sanitizedFraction(warningCoalitionFraction, fallback: 0.50)
        self.warningCoalitionFraction = warning
        self.criticalCoalitionFraction = max(
            warning,
            Self.sanitizedFraction(criticalCoalitionFraction, fallback: 0.70)
        )
        let availableWarning = Self.sanitizedFraction(warningAvailableFraction, fallback: 0.20)
        self.warningAvailableFraction = availableWarning
        self.criticalAvailableFraction = min(
            availableWarning,
            Self.sanitizedFraction(criticalAvailableFraction, fallback: 0.10)
        )
    }

    /// The conservative default aggregate policy.
    public static let `default` = Self()

    /// Computes severity without making the result actionable.
    public func severity(for sample: MemoryPressureAggregateSample) -> MemoryPressureSeverity {
        guard sample.coverage != .unavailable,
              let aggregateBytes = sample.aggregateBytes,
              let physicalMemoryBytes = sample.physicalMemoryBytes,
              physicalMemoryBytes > 0 else {
            return .normal
        }

        let warningBytes = thresholdBytes(
            physicalMemoryBytes: physicalMemoryBytes,
            fraction: warningCoalitionFraction
        )
        let criticalBytes = thresholdBytes(
            physicalMemoryBytes: physicalMemoryBytes,
            fraction: criticalCoalitionFraction
        )
        var severity: MemoryPressureSeverity
        if aggregateBytes >= criticalBytes {
            severity = .critical
        } else if aggregateBytes >= warningBytes {
            severity = .warning
        } else {
            severity = .normal
        }

        if severity >= .warning,
           let availableMemoryBytes = sample.availableMemoryBytes {
            let criticalAvailableBytes = thresholdBytes(
                physicalMemoryBytes: physicalMemoryBytes,
                fraction: criticalAvailableFraction
            )
            let warningAvailableBytes = thresholdBytes(
                physicalMemoryBytes: physicalMemoryBytes,
                fraction: warningAvailableFraction
            )
            if availableMemoryBytes <= criticalAvailableBytes {
                severity = .critical
            } else if availableMemoryBytes <= warningAvailableBytes {
                severity = max(severity, .warning)
            }
        }
        return severity
    }

    /// Evaluates one sample into a snapshot carrying completeness metadata.
    public func evaluate(sample: MemoryPressureAggregateSample) -> MemoryPressureAggregateSnapshot {
        MemoryPressureAggregateSnapshot(sample: sample, severity: severity(for: sample))
    }

    private static func sanitizedFraction(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0.05), 0.95)
    }

    private func thresholdBytes(physicalMemoryBytes: UInt64, fraction: Double) -> UInt64 {
        let value = Double(physicalMemoryBytes) * fraction
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(UInt64.max) ? UInt64.max : UInt64(value.rounded(.down))
    }
}
