import Foundation
import Testing

@testable import CmuxMemoryPressure

@Suite("Aggregate memory pressure")
struct MemoryPressureAggregatePolicyTests {
    @Test("lower bounds report severity but remain non-actionable")
    func lowerBoundIsDiagnosticOnly() {
        let sample = MemoryPressureAggregateSample(
            source: .descendantProcessTree,
            aggregateBytes: 5_000,
            physicalMemoryBytes: 8_000,
            availableMemoryBytes: nil,
            processCount: 3,
            missingProcessCount: 1,
            missingReason: .unreadableProcessRecord,
            sampledAt: Date(timeIntervalSince1970: 1)
        )
        let snapshot = MemoryPressureAggregatePolicy.default.evaluate(sample: sample)

        #expect(snapshot.coverage == .lowerBound)
        #expect(snapshot.severity == .warning)
        #expect(!snapshot.isActionable)
        #expect(snapshot.missingReason == .unreadableProcessRecord)
    }

    @Test("accounting saturates and deduplicates")
    func accountingIsBounded() {
        let result = MemoryPressureAggregateAccounting().summarize([
            .init(pid: 1, bytes: UInt64.max),
            .init(pid: 1, bytes: 10),
            .init(pid: 2, bytes: 1)
        ])

        #expect(result.aggregateBytes == UInt64.max)
        #expect(result.uniquePIDs == [1, 2])
        #expect(result.duplicatePIDs == [1])
    }
}
