@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The main-thread work of one omnibar key does not grow with the open tabs (HOT PATH AUDIT browser,
/// handoff/hot-path-audit/browser/AUDIT.md row 6). The Switch to Tab rows come from an index of the profile's open
/// tabs that changes when a tab opens, closes or navigates; a key only queries it. Before, every key rebuilt and
/// sorted the whole open-tab list on the main thread (`TabContentCache.openTabRows`, read by
/// `OmniboxSuggestionEngine.deliveries`) and handed it to the index actor, which compared it and re-indexed it.
///
/// Counted, not timed: the pages' `state` reads on the main thread during one key's synchronous turn
/// (`deliveries(for:)`), at 10 and at 100 open tabs. They must not depend on the tab count.
@MainActor @Suite(.serialized)
struct OmnibarOpenTabsPerKeyTests {
    @Test func aKeyReadsNoPagePerOpenTab() {
        let few = Self.stateReadsPerKey(openTabs: 10)
        let many = Self.stateReadsPerKey(openTabs: 100)
        print("OMNIBAR-OPEN-TABS page state reads per key: \(few) at 10 tabs, \(many) at 100 tabs")
        #expect(many == few, "a key read \(few) page states at 10 open tabs and \(many) at 100")
    }

    /// The index still follows the tabs: a row for each open tab, its new address after a navigation, gone once the tab
    /// closes, and never the asking tab's own.
    @Test func switchToTabRowsFollowOpenNavigateAndClose() async {
        let (cache, pages) = Self.cache(openTabs: 3)
        let engine = cache.suggestionEngine
        #expect(await Self.switchRows(engine, "site1", asking: nil) == ["tab-1"])
        #expect(await Self.switchRows(engine, "site1", asking: "tab-1").isEmpty, "the asking tab is never its own row")

        pages[2].load(URL(string: "https://moved.example/there")!)
        #expect(await Self.switchRows(engine, "moved", asking: nil) == ["tab-2"], "a navigated tab's row follows it")
        #expect(await Self.switchRows(engine, "site2", asking: nil).isEmpty, "its old address is no longer offered")

        cache.release("tab-0")
        #expect(await Self.switchRows(engine, "site0", asking: nil).isEmpty, "a closed tab's row leaves")
    }

    /// The Switch to Tab rows for `text`, once every open-tab change the cache made so far is in the index.
    static func switchRows(_ engine: OmniboxSuggestionEngine, _ text: String, asking: String?) async -> [String] {
        // The feed follows each page on the main actor's next turns: let it run, then wait for the index.
        for _ in 0..<20 { await Task.yield() }
        await engine.openTabsSettled()
        let gate = OmniboxGenerationGate()
        gate.begin(1)
        var rows: [BrowserSuggestion] = []
        for await delivery in engine.deliveries(for: OmniboxRequest(text: text, generation: 1, gate: gate, tabKey: asking)) {
            if case .local(let local) = delivery { rows = local }
        }
        return rows.filter { $0.kind == .switchToTab }.compactMap(\.tabKey)
    }

    /// A cache holding `count` open Chromium-kind pages of the default profile, each on its own URL and title.
    static func cache(openTabs count: Int) -> (TabContentCache, [MockBrowserTab]) {
        let cache = TabContentCache(daemon: DaemonService(),
                                    cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()),
                                    fileInput: NoFileInput())
        let engine = MockBrowserEngine(kind: .cef)
        var pages: [MockBrowserTab] = []
        for index in 0..<count {
            let url = URL(string: "https://site\(index).example/page/\(index)")
            let page = engine.makeMockTab(BrowserTabConfiguration(initialURL: url))
            page.simulate(.titleChanged("Open tab \(index)"))
            _ = cache.install(page, for: "tab-\(index)")
            pages.append(page)
        }
        return (cache, pages)
    }

    /// The pages' `state` reads in the synchronous turn of one omnibar key (the rows themselves come later).
    static func stateReadsPerKey(openTabs count: Int) -> Int {
        let (cache, pages) = cache(openTabs: count)
        let engine = cache.suggestionEngine
        let gate = OmniboxGenerationGate()
        gate.begin(1)
        _ = engine.deliveries(for: OmniboxRequest(text: "o", generation: 1, gate: gate, tabKey: "tab-0")) // warm-up
        let before = pages.reduce(0) { $0 + $1.stateReads }
        gate.begin(2)
        _ = engine.deliveries(for: OmniboxRequest(text: "op", generation: 2, gate: gate, tabKey: "tab-0"))
        return pages.reduce(0) { $0 + $1.stateReads } - before
    }
}

/// The main-thread time of one omnibar key's synchronous turn at 10, 100 and 500 open tabs: p50, p95, max over
/// 200 keys each. A measurement, not a gate:
///
/// ```
/// CMUX_OMNIBAR_TABS_BENCH=1 CMUX_SWIFT_SUITE_CONFIGURATION=release \
///   scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext OmnibarOpenTabsPerKeyBench
/// ```
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_OMNIBAR_TABS_BENCH"] == "1"))
struct OmnibarOpenTabsPerKeyBench {
    @Test func mainThreadTimePerKey() {
        for count in [10, 100, 500] {
            let (cache, _) = OmnibarOpenTabsPerKeyTests.cache(openTabs: count)
            let engine = cache.suggestionEngine
            let gate = OmniboxGenerationGate()
            let words = ["o", "op", "ope", "open", "open ", "open t", "open ta", "open tab", "s", "si", "sit", "site"]
            var generation: UInt64 = 0
            for word in words {
                generation += 1
                gate.begin(generation)
                _ = engine.deliveries(for: OmniboxRequest(text: word, generation: generation, gate: gate, tabKey: "tab-0"))
            }
            var samples: [Double] = []
            for index in 0..<200 {
                generation += 1
                gate.begin(generation)
                let request = OmniboxRequest(text: words[index % words.count], generation: generation, gate: gate, tabKey: "tab-0")
                let start = DispatchTime.now().uptimeNanoseconds
                _ = engine.deliveries(for: request)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000)
            }
            samples.sort()
            func at(_ q: Double) -> Double { samples[min(samples.count - 1, Int(Double(samples.count - 1) * q))] }
            print(String(format: "OMNIBAR-OPEN-TABS-BENCH tabs=%d main_us_per_key p50=%.1f p95=%.1f max=%.1f (200 keys, %@ build)",
                         count, at(0.5), at(0.95), samples.last ?? 0, _isDebugAssertConfiguration() ? "debug" : "optimized"))
        }
        #expect(Bool(true))
    }
}
