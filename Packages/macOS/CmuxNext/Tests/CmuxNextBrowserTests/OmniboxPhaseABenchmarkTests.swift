@testable import CmuxNextBrowser
import Foundation
import Testing

/// The phase A budget (plans/cmux-next/omnibar-suggestions.md, "Verification"):
/// 20,000 history rows (the cap), 500 bookmarks and 12 open tabs; 2,000 one-
/// and two-token word prefixes; the whole phase A call, merge included, timed
/// one query at a time. The design budget is 8 ms p99: an optimized build
/// (CMUX_SWIFT_SUITE_CONFIGURATION=release) asserts it; the default debug gate
/// asserts 10 ms. Both print the measured numbers.
nonisolated struct OmniboxPhaseABenchmarkTests {
    @Test func phaseAStaysInsideItsBudgetOverTwentyThousandRows() {
        let rows = OmniboxFixtures.rows(OmniboxQuickIndex.defaultCap, seed: 2026)
        var history = OmniboxQuickIndex()
        history.reset(rows, now: OmniboxFixtures.now)
        #expect(history.count == OmniboxQuickIndex.defaultCap)
        var bookmarks = OmniboxQuickIndex(admission: .all)
        bookmarks.reset(Array(OmniboxFixtures.rows(500, seed: 9)), now: OmniboxFixtures.now)
        let tabRows = OmniboxFixtures.rows(12, seed: 10)
        var tabs = OmniboxQuickIndex(admission: .all)
        tabs.reset(tabRows, now: OmniboxFixtures.now)
        let tabKeys = Dictionary(uniqueKeysWithValues: tabRows.enumerated().map { pair in
            (BrowserHistoryRanker.dedupeKey(for: pair.element.url), "tab-\(pair.offset)")
        })
        let gate = OmniboxGenerationGate()
        let queries = OmniboxFixtures.queries(2_000, from: rows, seed: 77)
        let clock = ContinuousClock()
        var durations: [Duration] = []
        // Where the time goes: the what-you-typed row, the history lookup, and the whole call by input length.
        var primary: [Duration] = [], lookup: [Duration] = [], byLength: [Int: [Duration]] = [:]
        var answered = 0
        for (index, text) in queries.enumerated() {
            let query = OmniboxLocalQuery(generation: UInt64(index), gate: gate, text: text, resolver: OmniboxResolver(),
                                          now: OmniboxFixtures.now)
            var result: [BrowserSuggestion] = []
            let whole = clock.measure {
                result = OmniboxPhaseA.rows(for: query, history: history, bookmarks: bookmarks, tabs: tabs, tabKeys: tabKeys)
            }
            durations.append(whole)
            byLength[min(text.count, 4), default: []].append(whole)
            primary.append(clock.measure { _ = OmniboxPhaseA.primary(for: text, resolver: query.resolver) })
            lookup.append(clock.measure { _ = history.search(text, now: OmniboxFixtures.now, limit: 8) })
            if result.count > 1 { answered += 1 }
        }
        func percentile99(_ values: [Duration]) -> Duration { values.isEmpty ? .zero : values.sorted()[values.count * 99 / 100] }
        durations.sort()
        let p50 = durations[durations.count / 2], p99 = percentile99(durations)
        let optimized = !_isDebugAssertConfiguration()
        print("R110 phase A (\(optimized ? "optimized" : "debug") build) over \(history.count) rows, \(queries.count) queries: p50 \(p50), p99 \(p99), max \(durations.last ?? .zero)")
        print("R110 phase A p99 by part: what-you-typed \(percentile99(primary)), history lookup \(percentile99(lookup)); by input length "
              + byLength.keys.sorted().map { "\($0)\($0 == 4 ? "+" : ""): \(percentile99(byLength[$0] ?? []))" }.joined(separator: ", "))
        #expect(answered > queries.count / 2, "most prefixes find rows")
        #expect(p99 < .milliseconds(optimized ? 8 : 10), "p99 \(p99)")
    }
}
