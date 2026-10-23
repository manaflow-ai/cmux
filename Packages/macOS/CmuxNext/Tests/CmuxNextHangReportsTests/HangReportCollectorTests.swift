@testable import CmuxNextHangReports
import Foundation
import Testing

/// The watchdog sink counts every stall, keeps the stacks of the longest, does nothing while off,
/// and the aggregate survives a relaunch.
struct HangReportCollectorTests {
    private func collector(resolved: @escaping @Sendable ([UInt]) -> [HangReportFrame] = { _ in [HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: 1)] })
        -> HangReportCollector {
        HangReportCollector(resolve: resolved, schedule: { $0() })
    }

    private static func nanos(_ ms: Int) -> UInt64 { UInt64(ms) * 1_000_000 }

    @Test func offRecordsNothing() {
        let collector = collector()
        collector.noteStall(durationNanos: Self.nanos(400), cpuNanos: 0, addresses: [1])
        collector.noteHang(durationNanos: Self.nanos(2_000), addresses: [1])
        #expect(collector.drain().isEmpty)
    }

    @Test func countsEveryStallAndKeepsTheEightLongestStacks() {
        let collector = collector()
        collector.setEnabled(true)
        for ms in [60, 120, 260, 300, 310, 320, 330, 340, 350, 360, 370, 1_500, 2_500] {
            collector.noteStall(durationNanos: Self.nanos(ms), cpuNanos: Self.nanos(ms / 2), addresses: [1, 2])
        }
        let aggregate = collector.drain()
        #expect(aggregate.histogram == [
            HistogramBucket(lowMs: 50, highMs: 100, count: 1), HistogramBucket(lowMs: 100, highMs: 250, count: 1),
            HistogramBucket(lowMs: 250, highMs: 500, count: 9), HistogramBucket(lowMs: 1_000, highMs: 2_000, count: 1),
            HistogramBucket(lowMs: 2_000, highMs: 5_000, count: 1),
        ])
        // A hang-length stall is only counted; its stack comes from noteHang.
        #expect(aggregate.stalls.map(\.durationMs) == [1_500, 370, 360, 350, 340, 330, 320, 310])
        #expect(aggregate.stalls.allSatisfy { $0.kind == .stall && $0.source == .watchdog && !$0.frames.isEmpty })
        #expect(aggregate.stalls.first?.cpuMs == 750)
        #expect(collector.drain().isEmpty)
    }

    @Test func hangsKeepTheirStackSampledWhileTheyRan() {
        let collector = collector()
        collector.setEnabled(true)
        collector.noteHang(durationNanos: Self.nanos(2_000), addresses: [1])
        #expect(collector.snapshot().hangs.map(\.kind) == [.hang])
    }

    @Test func turningOffDropsWhatWasRecorded() {
        let collector = collector()
        collector.setEnabled(true)
        collector.noteStall(durationNanos: Self.nanos(400), cpuNanos: 0, addresses: [1])
        collector.setEnabled(false)
        collector.setEnabled(true)
        #expect(collector.drain().isEmpty)
    }

    @Test func anAggregateSurvivesEncodingAndMerges() throws {
        var aggregate = StallAggregate()
        aggregate.count(durationMs: 70)
        aggregate.keep(HangSample(source: .watchdog, kind: .stall, durationMs: 400, frames: [.other]))
        let decoded = try JSONDecoder().decode(StallAggregate.self, from: JSONEncoder().encode(aggregate))
        #expect(decoded == aggregate)
        let collector = collector()
        collector.setEnabled(true)
        collector.noteStall(durationNanos: Self.nanos(80), cpuNanos: 0, addresses: [])
        collector.merge(decoded)
        let merged = collector.drain()
        #expect(merged.histogram == [HistogramBucket(lowMs: 50, highMs: 100, count: 2)])
        #expect(merged.stalls.count == 1)
    }

    @Test func coarseCountsAreBuckets() {
        #expect([0, 1, 2, 5, 6, 10, 11, 30, 31, 100, 101, 5_000].map(CoarseCounts.bucket)
            == ["0", "1", "2-5", "2-5", "6-10", "6-10", "11-30", "11-30", "31-100", "31-100", "101+", "101+"])
    }
}
