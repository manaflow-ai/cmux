import AppKit
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Leo 2026-11-18: "we draw the visible area, right? Like, that's what we're supposed to do." The tab strip and the
/// vertical tab list at 100 and 10,000 tabs: the strip has cells only for the tabs within a viewport of its view
/// (`TabStripView+VisibleCells`), a scroll step frames only those, and a one-tab change draws that tab alone; the list
/// draws only the rows in the rect AppKit asks for, lays nothing out for a change that moves no row, redraws only the
/// rows a change touched and makes no row element until an accessibility client asks. Prints `VISIBLE-ONLY ...`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)), .closesItsWindows)
struct VisibleOnlyTabsTests {
    @MainActor struct Strip {
        let window: NSWindow
        let strip: TabStripView
        let model: TabStripModel

        init(count: Int) {
            let items = (0..<count).map { TabItem(id: TabID("t\($0)"), title: "Tab number \($0)") }
            model = TabStripModel(tabs: items, selectedID: items.first?.id)
            strip = TabStripView(model: model)
            strip.dragsWindowFromEmptySpace = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            strip.frame = NSRect(x: 0, y: 0, width: 1400, height: TabStripView.preferredHeight)
            window.contentView = strip
            window.orderFrontRegardless()
            strip.layoutSubtreeIfNeeded()
            strip.syncFromModel()
            strip.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }

        /// The tabs one viewport and one more each side hold at the narrowest tab, and a few held ones.
        var bound: Int { Int((3 * strip.viewportWidth / strip.metrics.minInactiveTabWidth).rounded(.up)) + 6 }

        /// Frames written per cell so far.
        var frames: [TabID: Int] { strip.cells.mapValues { $0.workCounts.frames } }

        /// Frames written since `before`.
        func written(since before: [TabID: Int]) -> Int {
            strip.cells.reduce(0) { $0 + $1.value.workCounts.frames - (before[$1.key] ?? 0) }
        }

        /// A wheel step of `delta` points (`scrollWheel`'s path).
        func scroll(by delta: CGFloat) {
            strip.scrollOffset = TabScrollMath.clamp(strip.scrollOffset + delta, contentWidth: strip.result.contentWidth,
                                                     viewportWidth: strip.viewportWidth)
            strip.applyFrames()
        }
    }

    @Test(arguments: [100, 10_000])
    func theStripHasCellsForTheTabsInViewOnly(_ count: Int) {
        let harness = Strip(count: count)
        defer { harness.window.close() }
        let strip = harness.strip
        #expect(strip.result.isOverflowing, "SETUP: \(count) tabs fit in 1400 pt")
        let mounted = strip.cells.count
        #expect(mounted <= harness.bound, "\(mounted) cells for \(count) tabs; a viewport and one each side hold \(harness.bound)")

        // One wheel step frames the cells near the view only, and makes only the ones it reveals.
        strip.rowPasses = TabStripRowPasses()
        let before = harness.frames
        harness.scroll(by: 40)
        let written = harness.written(since: before)
        let made = strip.rowPasses.cellsMade
        #expect(written <= harness.bound, "a 40 pt scroll wrote \(written) cell frames")
        #expect(made <= Int((40 / strip.metrics.minInactiveTabWidth).rounded(.up)) + 1, "a 40 pt scroll made \(made) cells")

        // Through the strip a viewport at a time: the cells stay as many.
        var most = 0
        for _ in 0..<20 {
            harness.scroll(by: strip.viewportWidth)
            most = max(most, strip.cells.count)
        }
        #expect(most <= harness.bound, "scrolling held \(most) cells")
        print("VISIBLE-ONLY strip n=\(count) cells=\(mounted) bound=\(harness.bound) scroll40.framed=\(written) scroll40.made=\(made) scrolled.max=\(most)")
    }

    @Test(arguments: [100, 10_000])
    func oneTabsChangeDrawsThatTabAlone(_ count: Int) throws {
        let harness = Strip(count: count)
        defer { harness.window.close() }
        let strip = harness.strip, model = harness.model
        // A tab in view: its cell draws again, no other does, and nothing is laid out.
        strip.rowPasses = TabStripRowPasses()
        model.tabs[3].title = "Renamed"
        strip.syncFromModel()
        let shown = strip.rowPasses
        #expect(shown.cellsConfigured == 1 && shown.layouts == 0 && shown.frames == 0 && shown.cellsMade == 0, "\(shown)")
        #expect(strip.cells[TabID("t3")]?.item.title == "Renamed")
        // A tab out of view: nothing draws.
        strip.rowPasses = TabStripRowPasses()
        model.tabs[count - 1].title = "Far away"
        strip.syncFromModel()
        let hidden = strip.rowPasses
        #expect(hidden.cellsConfigured == 0 && hidden.layouts == 0 && hidden.cellsMade == 0, "\(hidden)")
        // Scrolled to, it shows the new title.
        harness.scroll(by: strip.result.contentWidth)
        #expect(strip.cells[TabID("t\(count - 1)")]?.item.title == "Far away")
        // A switch to a tab in view configures no cell's item and lays nothing out.
        strip.rowPasses = TabStripRowPasses()
        model.selectedID = try #require(strip.cells.keys.first { $0 != model.selectedID })
        strip.syncFromModel()
        #expect(strip.rowPasses.cellsConfigured == 0 && strip.rowPasses.layouts == 0, "\(strip.rowPasses)")
        print("VISIBLE-ONLY strip-change n=\(count) shown=\(shown) hidden=\(hidden)")
    }

    @Test(arguments: [100, 10_000])
    func farTabsStayReachable(_ count: Int) throws {
        let harness = Strip(count: count)
        defer { harness.window.close() }
        let strip = harness.strip, model = harness.model
        // Selecting the last tab gives it a cell and scrolls to it.
        let last = TabID("t\(count - 1)")
        model.selectedID = last
        strip.syncFromModel()
        CATransaction.flush()
        let cell = try #require(strip.cells[last], "the selected far tab has no cell")
        #expect(cell.isSelected)
        #expect(strip.cells.count <= harness.bound + 2, "\(strip.cells.count) cells")
        // Every tab is still an accessibility child, in order, with its cell's element where it has one.
        let children = strip.accessibilityChildren() ?? []
        let elements = children.compactMap { $0 as? TabAccessibilityElement }
        #expect(elements.count == count, "\(elements.count) tab elements for \(count) tabs")
        #expect(elements.last === cell.accessibility)
        #expect(elements.first?.accessibilityIdentifier() == "cmux.tabs.tab.t0")
    }

    // MARK: Vertical tabs

    @MainActor struct List {
        let window: NSWindow
        let list: VerticalTabListView
        let model: TabStripModel

        init(count: Int) {
            let items = (0..<count).map { TabItem(id: TabID("v\($0)"), title: "Tab number \($0)") }
            model = TabStripModel(tabs: items, selectedID: items.first?.id)
            list = VerticalTabListView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            list.frame = NSRect(x: 0, y: 0, width: VerticalTabListView.expandedWidth, height: 600)
            window.contentView = list
            window.orderFrontRegardless()
            list.layoutSubtreeIfNeeded()
            list.modelChanged()
        }

        /// The rows the view holds, and two.
        var bound: Int { Int((list.bounds.height / (list.metrics.rowHeight + list.metrics.rowSpacing)).rounded(.up)) + 2 }

        /// Draws the view as AppKit would.
        func draw() {
            guard let rep = list.bitmapImageRepForCachingDisplay(in: list.bounds) else { return }
            list.cacheDisplay(in: list.bounds, to: rep)
        }
    }

    @Test(arguments: [100, 10_000])
    func theListDrawsTheRowsInViewOnly(_ count: Int) throws {
        let harness = List(count: count)
        defer { harness.window.close() }
        let list = harness.list, model = harness.model
        #expect(list.maxScrollOffset > 0, "SETUP: \(count) rows fit")
        // No row element before an accessibility client asks.
        #expect(list.accessibilityRows.count == 0, "\(list.accessibilityRows.count) row elements made up front")

        list.passes = VerticalTabListPasses()
        harness.draw()
        let drawn = list.passes
        #expect(drawn.rowsVisited <= harness.bound && drawn.rowsDrawn <= harness.bound, "\(drawn)")

        // A scroll step draws the rows in view, and touches no element.
        _ = list.accessibilityChildren()
        list.passes = VerticalTabListPasses()
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0))
        list.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        harness.draw()
        let scrolled = list.passes
        #expect(scrolled.rowsVisited <= harness.bound && scrolled.accessibilityRowsConfigured == 0 && scrolled.layouts == 0, "\(scrolled)")

        // A switch redraws the two rows; a title change one row; neither lays the list out.
        list.passes = VerticalTabListPasses()
        model.selectedID = TabID("v3")
        list.modelChanged()
        let switched = list.passes
        #expect(switched.layouts == 0 && switched.wholeInvalidations == 0 && switched.rowInvalidations <= 2, "\(switched)")
        list.passes = VerticalTabListPasses()
        model.tabs[4].title = "Renamed"
        list.modelChanged()
        let renamed = list.passes
        #expect(renamed.layouts == 0 && renamed.wholeInvalidations == 0 && renamed.rowInvalidations == 1
                && renamed.accessibilityRowsConfigured == 1, "\(renamed)")
        #expect(list.listLayout.tabs[4].title == "Renamed")
        // A row out of view: nothing redraws.
        list.passes = VerticalTabListPasses()
        model.tabs[count - 1].title = "Far away"
        list.modelChanged()
        #expect(list.passes.rowInvalidations == 0 && list.passes.wholeInvalidations == 0 && list.passes.layouts == 0, "\(list.passes)")
        // A new tab lays the list out.
        list.passes = VerticalTabListPasses()
        model.tabs.append(TabItem(id: TabID("new"), title: "New"))
        list.modelChanged()
        #expect(list.passes.layouts == 1 && list.listLayout.frame(of: TabID("new")) != nil)
        print("VISIBLE-ONLY list n=\(count) drawn=\(drawn) scrolled=\(scrolled) switched=\(switched) renamed=\(renamed)")
    }
}
