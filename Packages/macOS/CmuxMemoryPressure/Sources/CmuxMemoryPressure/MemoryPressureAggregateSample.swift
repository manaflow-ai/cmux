public import Foundation

/// Raw metrics collected before aggregate-pressure policy is applied.
public struct MemoryPressureAggregateSample: Equatable, Sendable {
    /// The backend that produced the bytes.
    public let source: MemoryPressureAggregateSource
    /// The completeness state of the measured bytes.
    public let coverage: MemoryPressureAggregateCoverage
    /// The measured aggregate bytes, when any bytes were safely retained.
    public let aggregateBytes: UInt64?
    /// Installed physical memory used to evaluate relative thresholds.
    public let physicalMemoryBytes: UInt64?
    /// Available physical memory used as corroborating evidence.
    public let availableMemoryBytes: UInt64?
    /// Number of process records included in the selected source.
    public let processCount: Int
    /// Number of records that could not be included.
    public let missingProcessCount: Int
    /// Bounded reason for missing records, when coverage is incomplete.
    public let missingReason: MemoryPressureAggregateMissingReason?
    /// Time at which the sample was captured.
    public let sampledAt: Date

    /// Creates an aggregate sample and derives its coverage state.
    public init(
        source: MemoryPressureAggregateSource,
        aggregateBytes: UInt64?,
        physicalMemoryBytes: UInt64?,
        availableMemoryBytes: UInt64?,
        processCount: Int,
        missingProcessCount: Int,
        missingReason: MemoryPressureAggregateMissingReason? = nil,
        sampledAt: Date
    ) {
        self.source = source
        self.aggregateBytes = aggregateBytes
        self.physicalMemoryBytes = physicalMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.processCount = max(0, processCount)
        self.missingProcessCount = max(0, missingProcessCount)
        self.missingReason = missingReason
        self.sampledAt = sampledAt
        if source == .unavailable || aggregateBytes == nil {
            coverage = .unavailable
        } else if source == .coalition || self.missingProcessCount == 0 {
            coverage = .complete
        } else {
            coverage = .lowerBound
        }
    }

    /// Creates an unavailable sample at the supplied timestamp.
    public static func unavailable(sampledAt: Date) -> Self {
        Self(
            source: .unavailable,
            aggregateBytes: nil,
            physicalMemoryBytes: nil,
            availableMemoryBytes: nil,
            processCount: 0,
            missingProcessCount: 0,
            sampledAt: sampledAt
        )
    }

    /// Whether the sample is complete enough to authorize hibernation.
    public var isUsable: Bool {
        coverage == .complete &&
            aggregateBytes != nil &&
            (physicalMemoryBytes ?? 0) > 0
    }

    /// Returns the same sample with a different capture timestamp.
    public func withSampledAt(_ sampledAt: Date) -> Self {
        Self(
            source: source,
            aggregateBytes: aggregateBytes,
            physicalMemoryBytes: physicalMemoryBytes,
            availableMemoryBytes: availableMemoryBytes,
            processCount: processCount,
            missingProcessCount: missingProcessCount,
            missingReason: missingReason,
            sampledAt: sampledAt
        )
    }

    /// Returns the same sample with a replacement aggregate total.
    public func withAggregateBytes(_ aggregateBytes: UInt64?) -> Self {
        Self(
            source: source,
            aggregateBytes: aggregateBytes,
            physicalMemoryBytes: physicalMemoryBytes,
            availableMemoryBytes: availableMemoryBytes,
            processCount: processCount,
            missingProcessCount: missingProcessCount,
            missingReason: missingReason,
            sampledAt: sampledAt
        )
    }

    /// Returns aggregate-only diagnostics without PIDs, paths, commands, or arguments.
    public func privacySafeDiagnosticPayload() -> [String: Any] {
        [
            "source": source.rawValue,
            "coverage": coverage.rawValue,
            "aggregate_bytes": aggregateBytes.map { NSNumber(value: $0) } ?? NSNull(),
            "physical_memory_bytes": physicalMemoryBytes.map { NSNumber(value: $0) } ?? NSNull(),
            "available_memory_bytes": availableMemoryBytes.map { NSNumber(value: $0) } ?? NSNull(),
            "process_count": processCount,
            "process_count_available": source != .coalition,
            "missing_process_count": missingProcessCount,
            "missing_reason": missingReason?.rawValue as Any? ?? NSNull(),
            "complete": coverage == .complete,
            "known_lower_bound": coverage == .lowerBound
        ]
    }
}
