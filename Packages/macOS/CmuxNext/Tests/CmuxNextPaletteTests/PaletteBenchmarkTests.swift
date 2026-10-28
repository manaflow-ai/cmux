import CmuxNextActions
import CmuxNextPalette
import CmuxNextTestSupport
import Darwin
import Foundation
import Testing

/// Search cost (CPU time of the searching thread) over 2,000 items. The
/// budget is 1 ms per keystroke in an optimized build; debug builds (the
/// default `swift test`) run several times slower, so they get a looser bound. Run the strict check with
/// `swift test -c release --filter PaletteBenchmark`. With CMUX_PERF_RESULT_DIR every iteration's time per query
/// is result-v1 (lab story swift-palette-rank).
@Suite(.paletteRanker) struct PaletteBenchmarkTests {
    static var budgetMilliseconds: Double {
        #if DEBUG
        25
        #else
        1
        #endif
    }

    static func makeItems(count: Int) -> [PaletteItem] {
        let catalog = ActionCatalog.all
        let words = ["alpha", "build", "cargo", "deploy", "editor", "fleet", "ghostty", "harness", "iroh", "journal",
                     "kernel", "layout", "mobile", "nightly", "overlay", "palette", "queue", "router", "sidebar", "tunnel"]
        return (0..<count).map { i in
            let descriptor = catalog[i % catalog.count]
            let suffix = i < catalog.count ? "" : " \(words[i % words.count]) \(words[(i / 7) % words.count]) \(i)"
            return PaletteItem(
                id: "item\(i)",
                title: descriptor.title + suffix,
                subtitle: i.isMultiple(of: 3) ? "~/fun/\(words[i % words.count])/\(words[(i / 3) % words.count])" : nil,
                symbol: descriptor.symbol,
                keywords: descriptor.keywords + [descriptor.id.rawValue],
                primary: PaletteCommand(id: "run", title: "Run", effect: .perform {})
            )
        }
    }

    /// The CPU time of this thread of each iteration, in run order. Wall time also
    /// counts the time the thread waited for a core: with 32 suite processes
    /// on one host the ranking median read 123 ms against a 50 ms budget
    /// (78 s for the test), and the full scan beside it in this suite takes
    /// cores too. The body is synchronous (the ranker runs on the
    /// calling thread), so this thread's CPU time is the search cost.
    static func milliseconds(iterations: Int, _ body: () -> Void) -> [Double] {
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            body()
            samples.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6)
        }
        return samples
    }

    @Test func rankingOf2000ItemsFitsBudget() throws {
        var index = PaletteSearchIndex(items: Self.makeItems(count: 2000))
        var frecency = FrecencyStore()
        let now = Date()
        for i in stride(from: 0, to: 2000, by: 37) { frecency.record("item\(i)", at: now) }
        let ranker = PaletteRanker()
        let queries = ["sp", "tab", "new", "move", "close"]
        let perIteration = Self.milliseconds(iterations: 40) {
            for query in queries {
                _ = ranker.rank(index: &index, version: 1, query: query, sectionOrders: [], frecency: frecency, now: now, showsRecent: true)
                _ = ranker.rank(index: &index, version: 1, query: "q", sectionOrders: [], frecency: frecency, now: now, showsRecent: true)
            }
        }
        let perQuery = perIteration.map { $0 / Double(queries.count * 2) }
        try PerfResultWriter()?.record("swift.palette.rank_2000", unit: .ms, samples: perQuery)
        let median = perQuery.sorted()[perQuery.count / 2]
        print("palette benchmark: rank of 2000 items, median \(String(format: "%.3f", median)) ms per query")
        // Ranking adds sorting, grouping, and highlight positions; allow 2x.
        #expect(median < Self.budgetMilliseconds * 2, "median \(median) ms")
    }
}
