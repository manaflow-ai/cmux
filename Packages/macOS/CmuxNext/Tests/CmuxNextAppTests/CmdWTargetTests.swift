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
    /// the same tab again (which closed nothing: the page was already closing).
    @Test func aPressWhileAPageDecidesItsCloseClosesTheNextTab() {
        let strip = Self.strip(["a", "b", "c"], selected: "b")
        let closing: Set<String> = ["b"]
        #expect(strip.cmdWTarget(StripTabID("b"), closing: { closing.contains($0.rawValue) }) == StripTabID("c"))
        // The last tab closing: the one before it.
        #expect(strip.cmdWTarget(StripTabID("c"), closing: { ["b", "c"].contains($0.rawValue) }) == StripTabID("a"))
        // Nothing else open: nil (the press says why).
        #expect(strip.cmdWTarget(StripTabID("b"), closing: { _ in true }) == nil)
        // Not closing: the selected tab itself.
        #expect(strip.cmdWTarget(StripTabID("b"), closing: { _ in false }) == StripTabID("b"))
    }
}
