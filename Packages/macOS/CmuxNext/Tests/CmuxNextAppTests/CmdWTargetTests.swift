@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextTabs
import Testing

/// Which tab a person's Cmd-W closes while closes before it are still under way
/// (``TabStripModel/cmdWTarget(_:closing:skipped:)``): N quick presses close N tabs.
@MainActor @Suite
struct CmdWTargetTests {
    private static func strip(_ ids: [String], selected: String) -> TabStripModel {
        TabStripModel(tabs: ids.map { TabItem(id: TabID($0), title: $0) }, selectedID: TabID(selected))
    }

    /// A Chromium tab whose page decides its close (its beforeunload runs; the tab stays until
    /// Chromium closes the page) is closing: the next quick Cmd-W closes the tab after it, never
    /// the same tab again (which closed nothing: the page was already closing). The tab it closes is
    /// the one that close selects: the NEXT tab, the previous only when it was the last (the one
    /// close-selection rule, /work/wt/handoff/tasks/close-selection-rule.md R1 rank 4; it was the tab before).
    @Test func aPressWhileAPageDecidesItsCloseClosesTheTabItSelects() {
        let strip = Self.strip(["a", "b", "c"], selected: "b")
        let closing: Set<String> = ["b"]
        #expect(strip.cmdWTarget(StripTabID("b"), closing: { closing.contains($0.rawValue) }) == StripTabID("c"))
        #expect(strip.cmdWTarget(StripTabID("a"), closing: { ["a", "b"].contains($0.rawValue) }) == StripTabID("c"))
        // The last tab closing: the one before it.
        #expect(strip.cmdWTarget(StripTabID("c"), closing: { $0.rawValue == "c" }) == StripTabID("b"))
        #expect(strip.cmdWTarget(StripTabID("c"), closing: { ["b", "c"].contains($0.rawValue) }) == StripTabID("a"))
        // Nothing else open: nil (the press says why).
        #expect(strip.cmdWTarget(StripTabID("b"), closing: { _ in true }) == nil)
        // Not closing: the selected tab itself.
        #expect(strip.cmdWTarget(StripTabID("b"), closing: { _ in false }) == StripTabID("b"))
    }

    /// The tab that close selects is the target even when it cannot close: the press then closes
    /// nothing, never another tab, which that close never selects. Home's first tab cannot close:
    /// from Home, a with a (the last tab) closing, the close selects Home, so the press closes
    /// nothing. With a tab after it (Home, a, b) the close selects b, and the press closes b
    /// (close-selection-rule.md R1 rank 4: the next tab; it was the tab before, Home).
    @Test func aPressNeverClosesATabTheCloseBeforeItDoesNotSelect() {
        var tabs = ["home", "a"].map { TabItem(id: TabID($0), title: $0) }
        tabs[0].isClosable = false
        let strip = TabStripModel(tabs: tabs, selectedID: TabID("a"))
        #expect(strip.cmdWTarget(StripTabID("a"), closing: { $0.rawValue == "a" }) == nil)
        var three = ["home", "a", "b"].map { TabItem(id: TabID($0), title: $0) }
        three[0].isClosable = false
        #expect(TabStripModel(tabs: three, selectedID: TabID("a")).cmdWTarget(StripTabID("a"), closing: { $0.rawValue == "a" }) == StripTabID("b"))
        // A tab whose question shows is selected after the close too: the press closes nothing.
        let plain = Self.strip(["a", "x", "b"], selected: "a")
        #expect(plain.cmdWTarget(StripTabID("a"), closing: { $0.rawValue == "a" }, skipped: { $0.rawValue == "x" }) == nil)
        #expect(plain.cmdWTarget(StripTabID("a"), closing: { $0.rawValue == "a" }) == StripTabID("x"))
    }
}
