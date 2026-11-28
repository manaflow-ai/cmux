import CmuxNextSidebar
import Testing
@testable import CmuxNextApp

/// Leo, ask-5ad71ec59c: "Count work, not time" ... "synchronous calls made on the main thread per flush". A
/// sidebar row-feed flush maps its dirty rows on the main thread, and each ``SidebarRowBatch`` run is one
/// synchronous Rust call (`cmux_sidebar_face_rows`) for every row it staged. One flush makes one call, however
/// many rows changed in its frame and however long the sidebar: a change that maps rows one call each (the per-row
/// bridge traffic of #59531) fails here, in seconds, with no timing in it. Counts `row_batch_runs` and
/// `flush_sync_calls_max` (``SidebarView/perfCounters(reset:)``) and prints one `SIDEBAR-FLUSH-SYNC` line per case.
@MainActor @Suite(.serialized) struct SidebarFlushSyncCallsTests {
    /// The most synchronous main-thread calls one flush may make.
    static let budget = 1
    static let workspaces = 1_000

    struct Counts {
        var calls = 0, flushes = 0, maxPerFlush = 0, maps = 0
    }

    /// Runs `change`, then the frame's flush, and reads what the flush did.
    static func measure(_ fixture: SidebarLaneTickCostTests.Fixture, _ change: () -> Void) -> Counts {
        _ = SidebarView.perfCounters(reset: true)
        change()
        let work = fixture.pending.work
        fixture.pending.work.removeAll()
        work.forEach { $0() }
        let counters = SidebarView.perfCounters(reset: true)
        return Counts(calls: counters["row_batch_runs"] ?? 0, flushes: counters["row_flushes"] ?? 0,
                      maxPerFlush: counters["flush_sync_calls_max"] ?? 0, maps: counters["row_maps"] ?? 0)
    }

    static func report(_ name: String, _ counts: Counts) {
        print("SIDEBAR-FLUSH-SYNC \(name) n=\(workspaces) | flushes \(counts.flushes) | sync calls \(counts.calls) | "
            + "max per flush \(counts.maxPerFlush) (budget \(budget)) | rows mapped \(counts.maps)")
    }

    /// One agent's new step: its flush maps one row in one call.
    @Test func oneRowsFlushMakesOneCall() throws {
        try SidebarLaneTickCostTests.withLaneTunables {
            let fixture = SidebarLaneTickCostTests.Fixture(count: Self.workspaces)
            let counts = Self.measure(fixture) {
                fixture.lanes.lanes["s-7"] = SidebarLaneTickCostTests.Fixture.lane(7, step: "Editing SidebarRowFeed.swift")
            }
            Self.report("one-row", counts)
            #expect(counts.flushes == 1)
            #expect(counts.maps == 1, "one lane's step mapped \(counts.maps) rows")
            #expect(counts.maxPerFlush <= Self.budget, "one flush made \(counts.maxPerFlush) synchronous main-thread calls")
        }
    }

    /// 200 agents change in one frame: one flush maps their 200 rows, still in one call.
    @Test func manyRowsInOneFlushMakeOneCall() throws {
        try SidebarLaneTickCostTests.withLaneTunables {
            let fixture = SidebarLaneTickCostTests.Fixture(count: Self.workspaces)
            let counts = Self.measure(fixture) {
                for i in stride(from: 0, to: Self.workspaces, by: 5) {
                    fixture.lanes.lanes["s-\(i)"] = SidebarLaneTickCostTests.Fixture.lane(i, step: "Running tests \(i)")
                }
            }
            Self.report("200-rows", counts)
            #expect(counts.flushes == 1)
            #expect(counts.maps == 200, "200 lanes' steps mapped \(counts.maps) rows")
            #expect(counts.calls == counts.flushes, "\(counts.flushes) flush(es) made \(counts.calls) synchronous calls")
            #expect(counts.maxPerFlush <= Self.budget, "one flush of 200 rows made \(counts.maxPerFlush) synchronous main-thread calls")
        }
    }

    /// Duress: 300 frames of agent events over 1,000 workspaces, each frame 1 to 20 rows: no flush makes more than one call.
    @Test func everyFlushOfABusySidebarMakesOneCall() throws {
        try SidebarLaneTickCostTests.withLaneTunables {
            let fixture = SidebarLaneTickCostTests.Fixture(count: Self.workspaces)
            var total = Counts()
            for frame in 0..<300 {
                let counts = Self.measure(fixture) {
                    for k in 0..<(1 + frame % 20) {
                        let i = (frame * 37 + k * 101) % Self.workspaces
                        fixture.lanes.lanes["s-\(i)"] = SidebarLaneTickCostTests.Fixture.lane(i, step: "Frame \(frame) step \(k)")
                    }
                }
                total.calls += counts.calls
                total.flushes += counts.flushes
                total.maps += counts.maps
                total.maxPerFlush = max(total.maxPerFlush, counts.maxPerFlush)
            }
            Self.report("300-frames", total)
            #expect(total.flushes == 300)
            #expect(total.maxPerFlush <= Self.budget, "a flush made \(total.maxPerFlush) synchronous main-thread calls")
        }
    }
}
