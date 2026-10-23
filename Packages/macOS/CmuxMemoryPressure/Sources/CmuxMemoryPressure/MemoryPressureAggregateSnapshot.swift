public import Foundation

/// Aggregate policy output attached to a central memory-pressure snapshot.
public struct MemoryPressureAggregateSnapshot: Equatable, Sendable {
    /// The severity derived from the aggregate thresholds.
    public let severity: MemoryPressureSeverity
    /// The backend that produced the bytes.
    public let source: MemoryPressureAggregateSource
    /// The completeness state of the measured bytes.
    public let coverage: MemoryPressureAggregateCoverage
    /// The measured aggregate bytes, when available.
    public let aggregateBytes: UInt64?
    /// Installed physical memory used for threshold evaluation.
    public let physicalMemoryBytes: UInt64?
    /// Available physical memory used as corroborating evidence.
    public let availableMemoryBytes: UInt64?
    /// Number of measured process records.
    public let processCount: Int
    /// Number of omitted process records.
    public let missingProcessCount: Int
    /// Bounded reason for omitted records, when present.
    public let missingReason: MemoryPressureAggregateMissingReason?
    /// Time at which the source sample was captured.
    public let sampledAt: Date

    /// Creates a policy snapshot from one raw sample and its severity.
    public init(sample: MemoryPressureAggregateSample, severity: MemoryPressureSeverity) {
        self.severity = severity
        source = sample.source
        coverage = sample.coverage
        aggregateBytes = sample.aggregateBytes
        physicalMemoryBytes = sample.physicalMemoryBytes
        availableMemoryBytes = sample.availableMemoryBytes
        processCount = sample.processCount
        missingProcessCount = sample.missingProcessCount
        missingReason = sample.missingReason
        sampledAt = sample.sampledAt
    }

    /// Whether this snapshot can authorize idle-agent hibernation.
    public var isActionable: Bool {
        severity >= .warning &&
            coverage == .complete &&
            aggregateBytes != nil &&
            (physicalMemoryBytes ?? 0) > 0
    }
}
