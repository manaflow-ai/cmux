import Foundation

/// Identifies the source used for an aggregate process-memory sample.
enum MemoryPressureAggregateSource: String, Equatable, Sendable {
    /// macOS reported the resource coalition's instantaneous physical footprint.
    case coalition
    /// The process tree was enumerated and summed without a coalition API.
    case descendantProcessTree
    /// Neither a complete process tree nor a coalition footprint was available.
    case unavailable
}

/// A single process contribution used by the aggregate accounting reducer.
struct MemoryPressureAggregateProcessFootprint: Equatable, Sendable {
    let pid: Int
    let bytes: UInt64

    init(pid: Int, bytes: UInt64) {
        self.pid = pid
        self.bytes = bytes
    }
}

/// The deduplicated result of summing process footprints.
struct MemoryPressureAggregateAccountingResult: Equatable, Sendable {
    let aggregateBytes: UInt64
    let uniquePIDs: [Int]
    let duplicatePIDs: [Int]

    init(aggregateBytes: UInt64, uniquePIDs: [Int], duplicatePIDs: [Int]) {
        self.aggregateBytes = aggregateBytes
        self.uniquePIDs = uniquePIDs
        self.duplicatePIDs = duplicatePIDs
    }
}

/// Sums process footprints once per PID, even when roots overlap.
struct MemoryPressureAggregateAccounting: Sendable {
    func summarize(
        _ processes: [MemoryPressureAggregateProcessFootprint]
    ) -> MemoryPressureAggregateAccountingResult {
        var bytesByPID: [Int: UInt64] = [:]
        var duplicatePIDs: Set<Int> = []
        for process in processes where process.pid > 0 {
            guard bytesByPID[process.pid] == nil else {
                duplicatePIDs.insert(process.pid)
                continue
            }
            bytesByPID[process.pid] = process.bytes
        }

        let uniquePIDs = bytesByPID.keys.sorted()
        let aggregateBytes = uniquePIDs.reduce(into: UInt64(0)) { total, pid in
            let bytes = bytesByPID[pid] ?? 0
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            total = overflow ? UInt64.max : sum
        }
        return MemoryPressureAggregateAccountingResult(
            aggregateBytes: aggregateBytes,
            uniquePIDs: uniquePIDs,
            duplicatePIDs: duplicatePIDs.sorted()
        )
    }
}

/// Raw metrics collected before aggregate-pressure policy is applied.
struct MemoryPressureAggregateSample: Equatable, Sendable {
    let source: MemoryPressureAggregateSource
    let aggregateBytes: UInt64?
    let physicalMemoryBytes: UInt64?
    let availableMemoryBytes: UInt64?
    let processCount: Int
    let missingProcessCount: Int
    let sampledAt: Date

    init(
        source: MemoryPressureAggregateSource,
        aggregateBytes: UInt64?,
        physicalMemoryBytes: UInt64?,
        availableMemoryBytes: UInt64?,
        processCount: Int,
        missingProcessCount: Int,
        sampledAt: Date
    ) {
        self.source = source
        self.aggregateBytes = aggregateBytes
        self.physicalMemoryBytes = physicalMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.processCount = max(0, processCount)
        self.missingProcessCount = max(0, missingProcessCount)
        self.sampledAt = sampledAt
    }

    static func unavailable(sampledAt: Date) -> Self {
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

    /// A descendant sample with missing process records is incomplete and cannot
    /// safely drive an eviction decision. Coalition samples are already scoped
    /// and may still be used when the process listing races exits.
    var isUsable: Bool {
        source != .unavailable &&
            aggregateBytes != nil &&
            (physicalMemoryBytes ?? 0) > 0 &&
            (source == .coalition || missingProcessCount == 0)
    }

    func withSampledAt(_ sampledAt: Date) -> Self {
        Self(
            source: source,
            aggregateBytes: aggregateBytes,
            physicalMemoryBytes: physicalMemoryBytes,
            availableMemoryBytes: availableMemoryBytes,
            processCount: processCount,
            missingProcessCount: missingProcessCount,
            sampledAt: sampledAt
        )
    }

    func withAggregateBytes(_ aggregateBytes: UInt64?) -> Self {
        Self(
            source: source,
            aggregateBytes: aggregateBytes,
            physicalMemoryBytes: physicalMemoryBytes,
            availableMemoryBytes: availableMemoryBytes,
            processCount: processCount,
            missingProcessCount: missingProcessCount,
            sampledAt: sampledAt
        )
    }

    /// Returns aggregate-only diagnostics; it deliberately omits PIDs, paths,
    /// commands, arguments, and environment values.
    func privacySafeDiagnosticPayload() -> [String: Any] {
        [
            "source": source.rawValue,
            "aggregate_bytes": aggregateBytes.map { NSNumber(value: $0) } ?? NSNull(),
            "physical_memory_bytes": physicalMemoryBytes.map { NSNumber(value: $0) } ?? NSNull(),
            "available_memory_bytes": availableMemoryBytes.map { NSNumber(value: $0) } ?? NSNull(),
            "process_count": processCount,
            "missing_process_count": missingProcessCount,
            "complete": isUsable
        ]
    }
}

/// Policy result attached to each central memory-pressure snapshot.
struct MemoryPressureAggregateSnapshot: Equatable, Sendable {
    let severity: MemoryPressureSeverity
    let source: MemoryPressureAggregateSource
    let aggregateBytes: UInt64?
    let physicalMemoryBytes: UInt64?
    let availableMemoryBytes: UInt64?
    let processCount: Int
    let missingProcessCount: Int
    let sampledAt: Date

    init(sample: MemoryPressureAggregateSample, severity: MemoryPressureSeverity) {
        self.severity = severity
        source = sample.source
        aggregateBytes = sample.aggregateBytes
        physicalMemoryBytes = sample.physicalMemoryBytes
        availableMemoryBytes = sample.availableMemoryBytes
        processCount = sample.processCount
        missingProcessCount = sample.missingProcessCount
        sampledAt = sample.sampledAt
    }

    /// Only complete, real metrics may authorize a pressure-driven eviction.
    var isActionable: Bool {
        severity >= .warning &&
            source != .unavailable &&
            aggregateBytes != nil &&
            (source == .coalition || missingProcessCount == 0)
    }
}

/// Relative aggregate-memory policy shared by production and injectable tests.
///
/// The defaults are fractions of installed physical memory, never a fixed GB
/// value. A coalition/tree sample must cross the warning fraction before the
/// optional available-memory signal can raise its severity. This prevents an
/// unrelated low-memory application from causing cmux to terminate agent work.
struct MemoryPressureAggregatePolicy: Equatable, Sendable {
    let warningCoalitionFraction: Double
    let criticalCoalitionFraction: Double
    let warningAvailableFraction: Double
    let criticalAvailableFraction: Double

    init(
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

    static let `default` = Self()

    func severity(
        for sample: MemoryPressureAggregateSample,
        systemSeverity: MemoryPressureSeverity? = nil
    ) -> MemoryPressureSeverity {
        guard sample.isUsable,
              let aggregateBytes = sample.aggregateBytes,
              let physicalMemoryBytes = sample.physicalMemoryBytes,
              physicalMemoryBytes > 0 else {
            return systemSeverity ?? .normal
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

        // Available memory is a corroborating signal, not a standalone reason
        // to evict cmux work. It is intentionally considered only after the
        // cmux coalition/tree has crossed its relative warning boundary.
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
        return max(systemSeverity ?? .normal, severity)
    }

    func evaluate(
        sample: MemoryPressureAggregateSample,
        systemSeverity: MemoryPressureSeverity? = nil
    ) -> MemoryPressureAggregateSnapshot {
        MemoryPressureAggregateSnapshot(
            sample: sample,
            severity: severity(for: sample, systemSeverity: systemSeverity)
        )
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
