import CmuxNextTestSupport
@testable import CmuxNextWakeups
import Foundation
import Testing

/// The always-on cost of a lane item's stats (`// perf-hot: 100ns lane-item`), in nanoseconds: one
/// `CLOCK_UPTIME_RAW` read, one ``LaneStats/record(_:waitNanos:runNanos:)`` (four relaxed adds), and what
/// `LaneScheduler.runOnSlot` adds around an item's body (three clock reads and the record), each as the mean of
/// `items` in a row. A measurement, not a gate: run it in a Release build on each macOS major and quote the line. With
/// CMUX_PERF_RESULT_DIR it also writes each number as result-v1 (lab story swift-lane-item).
///
/// ```
/// CMUX_LANE_ITEM_BENCH=1 swift test -c release --filter LaneStatsBench
/// ```
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_LANE_ITEM_BENCH"] == "1"))
struct LaneStatsBench {
    private static let items = 2_000_000

    /// Nanoseconds per call of `body`, over `items` calls.
    private static func nanosPerItem(_ body: (Int) -> Void) -> Double {
        let start = LaneStats.uptimeNanos()
        for item in 0..<items { body(item) }
        return Double(LaneStats.uptimeNanos() - start) / Double(items)
    }

    @Test func alwaysOnCostPerLaneItem() throws {
        let stats = LaneStats()
        let priorities = WorkPriority.allCases
        var sink: UInt64 = 0
        let clock = Self.nanosPerItem { _ in sink &+= LaneStats.uptimeNanos() }
        _ = Self.nanosPerItem { item in stats.record(priorities[item & 3], waitNanos: UInt64(item), runNanos: 1_000) }  // warm
        let record = Self.nanosPerItem { item in
            stats.record(priorities[item & 3], waitNanos: UInt64(item & 0xFFFFF), runNanos: UInt64(item & 0xFFFF))
        }
        let perItem = Self.nanosPerItem { item in
            let queued = LaneStats.uptimeNanos()
            let started = LaneStats.uptimeNanos()
            let ended = LaneStats.uptimeNanos()
            stats.record(priorities[item & 3], waitNanos: started > queued ? started - queued : 0,
                         runNanos: ended > started ? ended - started : 0)
        }
        print(String(format: "lane-item bench: macOS %@, %d items: clock read %.1f ns, record %.1f ns, per item (3 reads + record) %.1f ns (sink %llu)",
                     ProcessInfo.processInfo.operatingSystemVersionString, Self.items, clock, record, perItem, sink))
        if let results = try PerfResultWriter() {
            try results.record("swift.lane_item.clock_read_ns", unit: .ns, samples: [clock])
            try results.record("swift.lane_item.record_ns", unit: .ns, samples: [record])
            try results.record("swift.lane_item.per_item_ns", unit: .ns, samples: [perItem])
        }
        #expect(stats.snapshot(lane: .cpu).contains { $0.run.count > 0 })
    }
}
