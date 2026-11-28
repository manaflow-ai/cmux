import Foundation
@testable import CmuxNextBrowser
import Testing

/// The saved back/forward entries around the engine's own list, ordered by Rust
/// (cmux-browser-rules `restored_history.rs`), keep the order the Swift rule had.
@Suite struct BrowserRestoredHistoryRulesFFITests {
    private func saved(_ name: String) -> BrowserSavedEntry { BrowserSavedEntry(url: URL(string: "https://\(name).test/")!, title: name) }
    private func entry(_ name: String?) -> BrowserNavigationEntry {
        BrowserNavigationEntry(url: name.flatMap { URL(string: "https://\($0).test/") }, title: name)
    }
    private func hosts(_ list: BrowserNavigationList) -> [String?] { list.entries.map { $0.url?.host() } }

    /// Saved a, b, [shown c], d: back [a, b], forward [d].
    private var history: BrowserRestoredHistory {
        BrowserRestoredHistory(entries: [saved("a"), saved("b"), saved("c"), saved("d")], current: 2)!
    }

    @Test func mergedPutsBackFirstThenTheEnginesFirstThenForwardThenTheRest() {
        let native = BrowserNavigationList(entries: [entry("c"), entry("x"), entry("y")], current: 2)
        let merged = history.merged(with: native, shown: entry("y"))
        #expect(hosts(merged) == ["a.test", "b.test", "c.test", "d.test", "x.test", "y.test"])
        #expect(merged.current == 5)
        #expect(history.position(of: native) == 5)
    }

    @Test func mergedKeepsTheEnginesFirstEntryCurrentOnItsFirstEntry() {
        let native = BrowserNavigationList(entries: [entry("c"), entry("x")], current: 0)
        let merged = history.merged(with: native, shown: entry("c"))
        #expect(merged.current == 2)
        #expect(history.position(of: native) == 2)
    }

    @Test func mergedWithoutANativeListUsesTheShownPage() {
        let merged = history.merged(with: nil, shown: entry("c"))
        #expect(hosts(merged) == ["a.test", "b.test", "c.test", "d.test"])
        #expect(merged.current == 2)
        #expect(BrowserRestoredHistory.empty.merged(with: nil, shown: entry("c")) == BrowserNavigationList(entries: [entry("c")], current: 0))
    }

    @Test func sessionSkipsEntriesWithoutAURLAndFollowsTheCurrentOne() {
        let native = BrowserNavigationList(entries: [entry("c"), entry(nil), entry("y")], current: 2)
        let session = history.session(around: native, shown: entry("y"))
        #expect(session.entries.map { $0.url.host() } == ["a.test", "b.test", "c.test", "d.test", "y.test"])
        #expect(session.current == 4)
    }

    @Test func sessionKeepsTheCurrentInRange() {
        let none = BrowserRestoredHistory.empty.session(around: BrowserNavigationList(entries: [entry(nil)], current: 0), shown: entry(nil))
        #expect(none.entries.isEmpty)
        #expect(none.current == 0)
    }
}
