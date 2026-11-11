import CmuxMobileChief
import Foundation
import Testing

// g. home_list_first_screen_under_load  the first Home window (as `home_list_first_screen`, god:
//                                       20 of 5,000 rows) while the whole god list is parsed in
//                                       the background, as the feed does right after the window,
//                                       on every core at once (a phone with few free cores, or a
//                                       busy host). Small: the same window with no load. 16 ms.
//
// The rule: the first screen always wins. The background parse runs at the feed's own priority
// (`MacHomeReply.wholeListPriority`), so the window under that load stays inside its budget; the
// 1.2x rule against the quiet window is the goal (known-red: see `why`). The note has the same window under the same load at `.userInitiated`,
// the priority the feed used before. Seen red on cmux#41052's simulator run 42983898372: god's
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

    /// The god window while every core parses the whole god list at `priority`.
    static func loaded(_ priority: TaskPriority) async throws -> (runs: [Double], parsed: Int) {
        let load = BackgroundParseLoad(wire: HomeInboxFixture.wire(.god), count: ProcessInfo.processInfo.activeProcessorCount,
                                       priority: priority)
        // Let the load reach every core before the clock starts.
        try await Task.sleep(for: .milliseconds(50)) // test: lets the background load start before timing
        let runs = try await window(.god)
        return (runs, await load.stop())
    }

    @Test("home_list_first_screen_under_load")
    func firstScreenUnderLoad() async throws {
        let quiet = try await Self.window(.small)
        let atFeedPriority = try await Self.loaded(MacHomeReply.wholeListPriority)
        let atOldPriority = try await Self.loaded(.userInitiated)
        InstantPerfReport.record(
            "home_list_first_screen_under_load", target: 16, small: quiet, god: atFeedPriority.runs,
            knownRed: [.ratio],
            why: "with every core parsing, the first window still shares the cores, caches and memory bandwidth with parses below its priority: about 8x the quiet window (18 ms vs 2.3 ms on a fleet simulator), against 620 ms when they ran at its priority",
            note: String(format: "small: the 20-row window, no load; god: the 20-of-5,000 window while %ld cores parse the whole god list (%ld B) at the feed's priority (%ld lists parsed). At .userInitiated (the feed before) the same window took %.2f ms",
                         ProcessInfo.processInfo.activeProcessorCount, HomeInboxFixture.wire(.god).count, atFeedPriority.parsed,
                         InstantPerfReport.median(atOldPriority.runs)))
    }
}
