import AppKit
@testable import CmuxNextTabs
import Testing
import CmuxNextTestSupport

/// A strip out of sight (a parked workspace's strip stays in its window, hidden) does no layout
/// for model changes: a script that adds, renames or reorders tabs in background workspaces costs
/// it nothing until it shows, and then it lands at the final state in one sync, with no motion
/// (CLAUDE.md "Go past Chrome where cmux is scripted").
///
/// A strip that was asked to sync while out of sight with its model as it was (a zoom of one pane asks the strip of
/// each pane it covers) does no layout when it shows again: it shows that model already.
@MainActor @Suite(.closesItsWindows, .serialized) struct TabStripHiddenSyncTests {
    /// A strip with `count` tabs in a view that a row hides and shows, in a window, laid out.
    private static func rig(tabs count: Int = 3) -> (model: TabStripModel, strip: TabStripView, parked: NSView, window: NSWindow) {
        let model = TabStripModel(tabs: (0..<count).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
        let strip = TabStripView(model: model)
        let parked = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 40))
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
        parked.addSubview(strip)
        let window = NSWindow(contentRect: parked.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = parked
        strip.layoutSubtreeIfNeeded()
        return (model, strip, parked, window)
    }

    /// The count is the layout engine's runs (`rowPasses.layouts`): each sync ends in one. Red before the mend: the
    /// strip shown again ran the whole sync, 1 run.
    @Test func aHiddenStripWithNoChangeDoesNoLayoutWhenItShows() async {
        let (model, strip, parked, window) = Self.rig()
        defer { window.closeAfterTest() }
        #expect(strip.cells.count == 3)

        parked.isHidden = true
        for _ in 0..<50 { await Task.yield() }
        strip.syncFromModel() // as the App's pane apply calls it, with no change in the model
        let runs = strip.rowPasses.layouts
        let frames = strip.cells.mapValues(\.frame)

        parked.isHidden = false
        #expect(strip.rowPasses.layouts == runs, "a strip whose tabs did not change ran the layout engine when it showed: \(runs) runs before, \(strip.rowPasses.layouts) after")
        #expect(strip.cells.mapValues(\.frame) == frames, "the strip shown again moved a tab")
        #expect(strip.displayed.map(\.id) == model.orderedTabs.map(\.id), "the strip shown again is not at the model's order")
    }

    /// The strip's own layout pass follows its width (`layout()`, `followWidth`), not the sync it owes: the tabs are
    /// where a strip that took the same width in sight has them.
    @Test func aHiddenStripThatChangedWidthShowsItsTabsAtTheNewWidth() throws {
        let (_, strip, parked, window) = Self.rig(tabs: 8)
        let twin = Self.rig(tabs: 8)
        defer { window.closeAfterTest(); twin.window.closeAfterTest() }
        let wide = strip.cells.mapValues(\.frame)
        twin.strip.setFrameSize(NSSize(width: 360, height: twin.strip.frame.height))
        twin.strip.layoutSubtreeIfNeeded()
        let narrow = twin.strip.cells.mapValues(\.frame)
        try #require(narrow != wide, "SETUP: 8 tabs sit the same in a 360 pt strip and a 700 pt strip")

        parked.isHidden = true
        strip.syncFromModel() // with no change in the model
        strip.setFrameSize(NSSize(width: 360, height: strip.frame.height)) // its pane got a new size while covered
        parked.layoutSubtreeIfNeeded()

        parked.isHidden = false
        parked.layoutSubtreeIfNeeded() // the window's layout pass after the show
        #expect(strip.viewportWidth == twin.strip.viewportWidth)
        #expect(strip.cells.mapValues(\.frame) == narrow, "the strip shown again has its tabs at \(strip.cells.mapValues(\.frame)), a 360 pt strip's are at \(narrow)")
    }

    @Test func aHiddenStripWhoseTabCameAndWentShowsItsModel() async {
        let (model, strip, parked, window) = Self.rig()
        defer { window.closeAfterTest() }
        let frames = strip.cells.mapValues(\.frame)

        parked.isHidden = true
        model.tabs.append(TabItem(id: TabID("tab3"), title: "Tab 3"))
        for _ in 0..<50 { await Task.yield() }
        strip.syncFromModel()
        model.tabs.removeLast() // the model is as the strip last showed it
        for _ in 0..<50 { await Task.yield() }
        strip.syncFromModel()

        parked.isHidden = false
        #expect(Set(strip.cells.keys) == Set(model.orderedTabs.map(\.id)), "the strip shown again shows \(strip.cells.keys.map(\.rawValue).sorted())")
        #expect(strip.displayed.map(\.id) == model.orderedTabs.map(\.id), "the strip shown again is not at the model's order")
        #expect(strip.cells.mapValues(\.frame) == frames, "the strip shown again moved a tab")
    }

    /// A hide ends closing mode (after a close under the pointer the tabs keep their widths), and only the sync that
    /// the strip owes lays its tabs out at its whole width then: also with its model as it was.
    @Test func aStripHiddenInClosingModeShowsItsTabsAtItsWholeWidth() throws {
        let (_, strip, parked, window) = Self.rig(tabs: 8)
        defer { window.closeAfterTest() }
        let whole = strip.cells.mapValues(\.frame)
        strip.closingModeWidth = strip.viewportWidth / 2
        strip.relayout(animated: false)
        try #require(strip.cells.mapValues(\.frame) != whole, "SETUP: the kept width moved no tab")

        parked.isHidden = true
        strip.syncFromModel() // with no change in the model
        #expect(strip.closingModeWidth == nil, "the hidden strip is in closing mode")

        parked.isHidden = false
        #expect(strip.cells.mapValues(\.frame) == whole, "the strip shown again has its tabs at \(strip.cells.mapValues(\.frame)), at its whole width they are at \(whole)")
    }

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
