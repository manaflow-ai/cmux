import Foundation

struct MemoryPressureStateTracker: Sendable {
    let thresholds: MemoryPressureFootprintThresholds
    let criticalPersistenceDuration: TimeInterval

    private var currentSeverity: MemoryPressureSeverity = .normal
    private var criticalBeganAt: Date?
    private var didReportPersistentCritical = false

    init(
        thresholds: MemoryPressureFootprintThresholds,
        criticalPersistenceDuration: TimeInterval
    ) {
        self.thresholds = thresholds
        self.criticalPersistenceDuration = criticalPersistenceDuration
    }

    mutating func ingest(
        systemSeverity: MemoryPressureSeverity?,
        physicalFootprintBytes: UInt64?,
        aggregateMemoryPressure: MemoryPressureAggregateSnapshot? = nil,
        sampledAt: Date
    ) -> MemoryPressureStateEvaluation {
        let previousSeverity = currentSeverity
        let footprintSeverity = thresholds.severity(
            forPhysicalFootprintBytes: physicalFootprintBytes
        )
        // Aggregate pressure is a distinct signal lane. Keep the legacy
        // system/footprint severity here so aggregate pressure cannot trigger
        // unrelated resource shedding or the persistent-critical callback.
        // The monitor dispatches the aggregate snapshot explicitly to the
        // aggregate responder after this evaluation.
        let nextSeverity = max(systemSeverity ?? .normal, footprintSeverity)
        currentSeverity = nextSeverity

        var didBecomePersistentCritical = false
        if nextSeverity == .critical {
            if criticalBeganAt == nil {
                criticalBeganAt = sampledAt
            }
            if let criticalBeganAt,
               !didReportPersistentCritical,
               sampledAt.timeIntervalSince(criticalBeganAt) >= criticalPersistenceDuration {
                didReportPersistentCritical = true
                didBecomePersistentCritical = true
            }
        } else {
            criticalBeganAt = nil
            didReportPersistentCritical = false
        }

        let snapshot = MemoryPressureSnapshot(
            severity: nextSeverity,
            physicalFootprintBytes: physicalFootprintBytes,
            aggregateMemoryPressure: aggregateMemoryPressure,
            sampledAt: sampledAt
        )
        return MemoryPressureStateEvaluation(
            previousSeverity: previousSeverity,
            snapshot: snapshot,
            didTransition: previousSeverity != nextSeverity,
            didBecomePersistentCritical: didBecomePersistentCritical
        )
    }
}
