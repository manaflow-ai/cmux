@testable import CmuxNextPalette
import Darwin
import Foundation
import Testing

/// What search memory costs Cmd-P: one query's rank over 1,000 workspaces, with no history and no
/// sidebar places (the ranker's input before search memory) and with a full history (the 500 rows
/// the daemon keeps, the learned picks of 600 runs) and every workspace's sidebar place. Also the
/// cost of building the rows (`WorkspacePaletteProvider.makeItems`, which now sorts by sidebar place).
///
/// A measurement, not a check: it runs only with `CMUX_CMDP_RANK_BENCH=1`, on an idle fleet host:
///
///     cmux-ci run --class exclusive --script scripts/measure/swift-test-bench.sh --ref SHA \
///       --arg Packages/macOS/CmuxNext --arg CmdPRankBench --arg config=release --arg enable=CMUX_CMDP_RANK_BENCH
@MainActor
@Suite(.paletteRanker, .enabled(if: ProcessInfo.processInfo.environment["CMUX_CMDP_RANK_BENCH"] == "1"))
struct CmdPRankBench {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace]
        init(_ workspaces: [PaletteWorkspace]) { self.workspaces = workspaces }
        func selectWorkspace(id: String) {}
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    private static let words = ["alpha", "build", "cargo", "deploy", "editor", "fleet", "ghostty", "harness", "iroh", "journal",
                                "kernel", "layout", "mobile", "nightly", "overlay", "palette", "queue", "router", "sidebar", "tunnel"]
    private static let count = 1000
    private static let queries = ["a", "al", "alp", "alpha", "build c", "fleet", "w12", "router 3", "zz", "sidebar tunnel"]

    private static func workspaces(ranked: Bool) -> [PaletteWorkspace] {
        (0..<count).map { index in
            PaletteWorkspace(id: "w\(index)", title: "\(words[index % 20]) \(words[(index / 20) % 20]) \(index)",
                             directory: "~/fun/\(words[(index / 3) % 20])",
                             // A shuffled sidebar: places differ from the source order.
                             sidebarRank: ranked ? (index * 7919) % count : nil)
        }
    }

    private static func history(full: Bool, now: Date) -> FrecencyStore {
        var store = FrecencyStore()
        guard full else { return store }
        for run in 0..<600 {
            let key = "workspace:w\((run * 13) % count)"
            let at = now.addingTimeInterval(-Double(run) * 60)
            store.record(key, at: at)
            store.recordPick(key, query: "\(words[run % 20]) \(words[(run / 3) % 20])", at: at)
        }
        return store
    }

    private static func cpuMilliseconds(_ body: () -> Void) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        body()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6
    }

    private static func percentiles(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        func at(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] }
        return String(format: "p50 %.3f ms, p95 %.3f ms, max %.3f ms (n=%d)", at(0.5), at(0.95), sorted.last ?? 0, sorted.count)
    }

    private static func measure(memory: Bool) -> (rows: String, rank: String) {
        let now = Date()
        let provider = WorkspacePaletteProvider(source: Workspaces(workspaces(ranked: memory)), showsItemsForEmptyQuery: true)
        var items: [PaletteItem] = []
        let rows = (0..<50).map { _ in cpuMilliseconds { items = provider.makeItems() } }
        var index = PaletteSearchIndex(items: items)
        let frecency = history(full: memory, now: now)
        let ranker = PaletteRanker()
        // Warm the prepared fields, as the open's first rank does.
        _ = ranker.rank(index: &index, version: 1, query: "a", sectionOrders: [], frecency: frecency, now: now, showsRecent: true)
        var samples: [Double] = []
        for _ in 0..<40 {
            for query in queries {
                samples.append(cpuMilliseconds {
                    _ = ranker.rank(index: &index, version: 1, query: query, sectionOrders: [], frecency: frecency, now: now, showsRecent: true)
                })
            }
        }
        return (percentiles(rows), percentiles(samples))
    }

    @Test func rankCostWithAndWithoutSearchMemory() {
        let before = Self.measure(memory: false)
        let after = Self.measure(memory: true)
        let picks = Self.history(full: true, now: Date()).picks.count
        print("cmdp bench: \(Self.count) workspaces, one query's rank, thread CPU")
        print("cmdp bench: no history, no sidebar places: rank \(before.rank); rows \(before.rows)")
        print("cmdp bench: 500 rows + \(picks) learned picks, sidebar places: rank \(after.rank); rows \(after.rows)")
        #expect(picks > 0)
    }
}
