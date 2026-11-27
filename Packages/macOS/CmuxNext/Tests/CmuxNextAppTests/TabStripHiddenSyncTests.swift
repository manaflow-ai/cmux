import AppKit
@testable import CmuxNextTabs
import Testing
import CmuxNextTestSupport

/// A strip out of sight (a parked workspace's strip stays in its window, hidden) does no layout
/// for model changes: a script that adds, renames or reorders tabs in background workspaces costs
/// it nothing until it shows, and then it lands at the final state in one sync, with no motion
/// (CLAUDE.md "Go past Chrome where cmux is scripted").
@MainActor @Suite(.closesItsWindows, .serialized) struct TabStripHiddenSyncTests {
    @Test func aHiddenStripSyncsOnceWhenItShows() async {
        let model = TabStripModel(tabs: (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
        let strip = TabStripView(model: model)
        let parked = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 40))
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
        parked.addSubview(strip)
        let window = NSWindow(contentRect: parked.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = parked
        strip.layoutSubtreeIfNeeded()
        #expect(strip.cells.count == 3)

        parked.isHidden = true
        model.tabs.append(TabItem(id: TabID("tab3"), title: "Tab 3"))
        model.tabs.swapAt(0, 1)
        for _ in 0..<50 { await Task.yield() } // the strip's model observation runs
        strip.syncFromModel() // as the App's pane apply calls it
        #expect(strip.cells[TabID("tab3")] == nil, "a hidden strip laid out a tab it does not show")

        parked.isHidden = false
        #expect(strip.cells[TabID("tab3")] != nil, "the strip shown again lacks the tab added while hidden")
        #expect(strip.displayed.map(\.id) == model.orderedTabs.map(\.id), "the strip shown again is not at the model's order")
    }
}
