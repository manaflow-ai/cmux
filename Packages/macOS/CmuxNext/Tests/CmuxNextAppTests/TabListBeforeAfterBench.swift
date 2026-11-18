import AppKit
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Scratch bench (not for merge): the same numbers on the base and on the visible-only head, through APIs both have.
/// Prints `TABLIST-BENCH ...`.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(10)))
struct TabListBeforeAfterBench {
    @Test(arguments: [100, 10_000])
    func strip(_ count: Int) {
        let items = (0..<count).map { TabItem(id: TabID("t\($0)"), title: "Tab number \($0)") }
        let model = TabStripModel(tabs: items, selectedID: items.first?.id)
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let buildStart = CACurrentMediaTime()
        strip.frame = NSRect(x: 0, y: 0, width: 1400, height: TabStripView.preferredHeight)
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        strip.syncFromModel()
        strip.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let build = CACurrentMediaTime() - buildStart
        func frames() -> Int { strip.cells.values.reduce(0) { $0 + $1.workCounts.frames } }
        // One title change of a shown tab.
        var passes = strip.rowPasses, written = frames()
        var start = CACurrentMediaTime()
        model.tabs[2].title = "Renamed"
        strip.syncFromModel()
        CATransaction.flush()
        let change = CACurrentMediaTime() - start
        let changeFrames = frames() - written, changeLayouts = strip.rowPasses.layouts - passes.layouts
        // One wheel step of 40 pt from the middle.
        strip.scrollOffset = (strip.result.contentWidth - strip.viewportWidth) / 2
        strip.applyFrames()
        CATransaction.flush()
        passes = strip.rowPasses
        written = frames()
        start = CACurrentMediaTime()
        strip.scrollOffset += 40
        strip.applyFrames()
        CATransaction.flush()
        let scroll = CACurrentMediaTime() - start
        let scrollFrames = frames() - written
        print(String(format: "TABLIST-BENCH strip n=%d cells=%d build=%.1fms change.frames=%d change.layouts=%d change=%.1fus "
                     + "scroll.frames=%d scroll=%.1fus", count, strip.cells.count, build * 1e3, changeFrames, changeLayouts,
                     change * 1e6, scrollFrames, scroll * 1e6))
        _ = passes
    }

    @Test(arguments: [100, 10_000])
    func vertical(_ count: Int) async {
        let items = (0..<count).map { TabItem(id: TabID("v\($0)"), title: "Tab number \($0)") }
        let model = TabStripModel(tabs: items, selectedID: items.first?.id)
        let list = VerticalTabListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        list.frame = NSRect(x: 0, y: 0, width: VerticalTabListView.expandedWidth, height: 600)
        window.contentView = list
        window.orderFrontRegardless()
        list.layoutSubtreeIfNeeded()
        list.modelChanged()
        func draw() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        draw()
        for _ in 0..<5 { await Task.yield() }
        let elementsAtRest = list.accessibilityRows.count
        // One title change.
        var start = CACurrentMediaTime()
        model.tabs[2].title = "Renamed"
        list.modelChanged()
        draw()
        let change = CACurrentMediaTime() - start
        let elementsAfterChange = list.accessibilityRows.count
        // A full draw of the view.
        start = CACurrentMediaTime()
        list.needsDisplay = true
        draw()
        let full = CACurrentMediaTime() - start
        print(String(format: "TABLIST-BENCH vertical n=%d elements.rest=%d elements.afterChange=%d change=%.1fus fullDraw=%.1fus",
                     count, elementsAtRest, elementsAfterChange, change * 1e6, full * 1e6))
    }
}
