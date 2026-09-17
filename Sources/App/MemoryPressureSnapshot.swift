import Foundation

struct MemoryPressureSnapshot: Equatable, Sendable {
    let severity: MemoryPressureSeverity
    let physicalFootprintBytes: UInt64?
    let aggregateMemoryPressure: MemoryPressureAggregateSnapshot?
    let sampledAt: Date

    init(
        severity: MemoryPressureSeverity,
        physicalFootprintBytes: UInt64?,
        aggregateMemoryPressure: MemoryPressureAggregateSnapshot? = nil,
        sampledAt: Date
    ) {
        self.severity = severity
        self.physicalFootprintBytes = physicalFootprintBytes
        self.aggregateMemoryPressure = aggregateMemoryPressure
        self.sampledAt = sampledAt
    }
}
