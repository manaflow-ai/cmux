import AppKit
import CmuxNextInput
@testable import CmuxNextTabs
import CmuxNextWakeups
import Testing

/// A strip out of sight (a parked workspace's strip stays in its window, hidden) does no layout
/// for model changes: a script that adds, renames or reorders tabs in background workspaces costs
/// it nothing until it shows, and then it lands at the final state in one sync, with no motion
/// (CLAUDE.md "Go past Chrome where cmux is scripted").
@MainActor @Suite(.serialized) struct TabStripHiddenSyncTests {
    /// A strip under `node` with a deadline placer of its own.
    private static func strip(_ model: TabStripModel, under node: VisibilityNode) -> TabStripView {
        TabStripView(model: model, input: InputEventTap(),
                     deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())), visibilityNode: node)
    }

    @Test func aHiddenStripSyncsOnceWhenItShows() async {
        let model = TabStripModel(tabs: (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
        let strip = TabStripView.testing(model: model)
        let parked = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 40))
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
        parked.addSubview(strip)
        let window = NSWindow(contentRect: parked.frame, styleMask: [.borderless], backing: .buffered, defer: false)
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

    /// Recipe R-hide: the strip follows its pane's node, not only AppKit's hidden flag.
    /// A suspended pane (its node hidden, its views still in the window and not hidden) lays out nothing for
    /// model changes, and its show applies the last one once.
    @Test func aStripUnderAHiddenNodeSyncsOnceWhenTheNodeShows() async {
        let model = TabStripModel(tabs: (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
        let pane = VisibilityNode(root: "pane", own: .visible)
        let strip = Self.strip(model, under: pane)
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
        let window = NSWindow(contentRect: strip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        #expect(strip.cells.count == 3 && strip.isShownInWindow)

        pane.set(.hidden)
        #expect(!strip.isShownInWindow, "a strip under a hidden node stayed in the window's fan-outs")
        model.tabs.append(TabItem(id: TabID("tab3"), title: "Tab 3"))
        for _ in 0..<50 { await Task.yield() } // the strip's model observation runs
        model.tabs.swapAt(0, 1)
        for _ in 0..<50 { await Task.yield() }
        strip.syncFromModel()
        #expect(strip.cells[TabID("tab3")] == nil, "a strip under a hidden node laid out a tab nobody sees")

        pane.set(.visible)
        #expect(strip.isShownInWindow)
        #expect(strip.cells[TabID("tab3")] != nil, "the shown strip lacks the tab added while hidden")
        #expect(strip.displayed.map(\.id) == model.orderedTabs.map(\.id), "the shown strip is not at the model's order")
        #expect(strip.visibilityNode.deferredCount == 0)
    }

    /// Recipe R-appear: a theme flip with 50 workspace strips in a window,
    /// one workspace on screen, re-themes the visible strip only; each other strip re-themes once when its
    /// workspace shows, however many flips came while it was hidden.
    @Test func aThemeFlipAtFiftyWorkspacesRestylesOnlyTheVisibleStrip() {
        let counts = VisibilityWorkCounts()
        let windowNode = VisibilityNode(root: "window", own: .visible, workCounts: counts)
        let workspaces = (0..<50).map { VisibilityNode("workspace:\($0)", own: $0 == 0 ? .visible : .hidden, parent: windowNode) }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 40))
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        let strips = workspaces.map { workspace in
            let model = TabStripModel(tabs: [TabItem(id: TabID("tab"), title: "Tab")], selectedID: TabID("tab"))
            let strip = Self.strip(model, under: workspace)
            strip.frame = content.bounds
            content.addSubview(strip)
            return strip
        }
        content.layoutSubtreeIfNeeded()

        counts.reset() // what AppKit's own appearance calls on joining the window ran
        for _ in 0..<2 { // dark, then light again, before any hidden workspace shows
            for strip in strips { strip.viewDidChangeEffectiveAppearance() }
        }
        #expect(counts.appearanceApplies == 2, "hidden strips re-themed for a flip nobody saw")

        for workspace in workspaces.dropFirst() { workspace.set(.visible) }
        #expect(counts.appearanceApplies == 2 + 49, "a shown strip did not re-theme exactly once")
        #expect(strips.allSatisfy { $0.visibilityNode.deferredCount == 0 })
    }
}
