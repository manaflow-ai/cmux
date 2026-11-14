import CmuxMobileChief
import Darwin
import Foundation
import Testing

// g. home_list_first_screen_under_load  the first Home window (as `home_list_first_screen`, god:
//                                       20 of 5,000 rows) while the whole god list is parsed in
//                                       the background, as the feed does right after the window,
//                                       on every core but one (a phone with few free cores, or a
//                                       busy host). Small: the 20-row window under the same load.
//                                       16 ms.
//
// The rule: the first screen always wins. The background parse runs at the feed's own priority
// (`MacHomeReply.wholeListPriority`). Small and god are both timed under the same load, so the 1.2x
// rule judges the list's size alone; what the load itself costs is held to the budget (3x target),
// and the note keeps the quiet and the old-priority numbers beside it. Small quiet against god loaded
// read 4.3x on the macOS runner (cmux#41225 run 43142793388: 1.44 vs 6.23 ms) while god quiet was
// 2.04 ms: that ratio measured the host's contention, not the 5,000 rows.
//
// The load leaves the painting thread its own core: with every core busy the
// window also shares caches and the allocator with the parses, whatever their priority (8x quiet
// on a 14-core fleet simulator, yet a clear pass on a 3-core hosted one). The note has the same
// window under the same load at `.userInitiated`, the priority the feed used before. Seen red on cmux#41052's simulator run 42983898372: god's
// window 6.06 ms vs 3.17 ms while that host parsed the whole list 2.7x slower than base's.

/// Parses `wire` again and again on `count` detached tasks at `priority` until stopped.
final class BackgroundParseLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var tasks: [Task<Int, Never>] = []

    init(wire: Data, count: Int, priority: TaskPriority) {
        tasks = (0..<count).map { _ in
            Task.detached(priority: priority) { [self] in
                var parsed = 0
                while !self.isStopped {
                    if (try? MacHomeReply(line: wire)) != nil { parsed += 1 }
                }
                return parsed
            }
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    /// Stops the load; the whole lists it parsed meanwhile.
    func stop() async -> Int {
        lock.withLock { stopped = true }
        var total = 0
        for task in tasks { total += await task.value }
        return total
    }
}

// Nested in `InstantPerfTests`, whose `.serialized` covers its child suites: a bench case never
// runs beside another (this target's suites would otherwise run in parallel).
extension InstantPerfTests {
    @MainActor
    @Suite("Instant list perf: Home under load", .serialized)
    struct HomeListLoadPerfTests {
        static func window(_ size: InstantPerfSize) async throws -> [Double] {
            let wire = HomeInboxFixture.firstWindowWire(size)
            return try await InstantPerfReport.sample {
                var list: MacHomeList?
                let elapsed = try ContinuousClock().measure { list = MacHomeList(try MacHomeReply(line: wire).rows) }
                #expect((list?.pinned.count ?? 0) + (list?.rows.count ?? 0) == min(HomeInboxFixture.rowCount(size), MacHomeRows.firstWindow))
                return elapsed
            }
        }

        /// Background parses: every core but the one the first screen paints on.
        static var loaders: Int { max(1, ProcessInfo.processInfo.activeProcessorCount - 1) }

        /// The `size` window while every other core parses the whole god list at `priority`.
        static func loaded(_ size: InstantPerfSize, _ priority: TaskPriority) async throws -> (runs: [Double], parsed: Int) {
            let load = BackgroundParseLoad(wire: HomeInboxFixture.wire(.god), count: Self.loaders,
                                           priority: priority)
            // Let the load reach every core before the clock starts.
            try await Task.sleep(for: .milliseconds(50)) // test: lets the background load start before timing
            let runs = try await window(size)
            return (runs, await load.stop())
        }

        /// Bytes the process's malloc zones hold allocated right now, in MB: live objects only,
        /// unlike the footprint, which keeps pages malloc has not given back yet.
        static func liveMB() -> Double {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return Double(stats.size_in_use) / 1_048_576
        }

        /// Whole-list reads in a row on one task, as a loader (or a feed that reads again before
        /// its task ends) does, leave nothing alive behind: what a read leaves autoreleased goes
        /// when it returns. Without the pools, each 5,000-row read kept its rows' autoreleased
        /// objects until the task ended: the loaders' footprint climbed by hundreds of MB, and
        /// freeing it all at once when they stopped slowed the next first screens to 2x for a
        /// second (base: home_list_first_screen read god 5.41 ms vs small 2.82 ms right after
        /// this suite's loads).
        @Test("a whole-list read leaves no autoreleased rows behind")
        func wholeListLeavesNothing() throws {
            let wire = HomeInboxFixture.wire(.god)
            _ = try MacHomeReply(line: wire)
            let before = Self.liveMB()
            for _ in 0..<5 { _ = try MacHomeReply(line: wire) }
            let grown = Self.liveMB() - before
            #expect(grown < 10, "five whole-list reads on one task left \(String(format: "%.1f", grown)) MB allocated")
        }

        @Test("home_list_first_screen_under_load")
        func firstScreenUnderLoad() async throws {
            let quietGod = try await Self.window(.god)
            let smallLoaded = try await Self.loaded(.small, MacHomeReply.wholeListPriority)
            let atFeedPriority = try await Self.loaded(.god, MacHomeReply.wholeListPriority)
            let atOldPriority = try await Self.loaded(.god, .userInitiated)
            InstantPerfReport.record(
                "home_list_first_screen_under_load", target: 16, small: smallLoaded.runs, god: atFeedPriority.runs,
                note: String(format: "small: the 20-row window, god: the 20-of-5,000 window, each while %ld cores parse the whole god list (%ld B) at the feed's priority (%ld lists parsed during small, %ld during god). The same god window with no load: %.2f ms; at .userInitiated (the feed before): %.2f ms",
                             Self.loaders, HomeInboxFixture.wire(.god).count, smallLoaded.parsed, atFeedPriority.parsed,
                             InstantPerfReport.median(quietGod), InstantPerfReport.median(atOldPriority.runs)))
        }
    }
}
