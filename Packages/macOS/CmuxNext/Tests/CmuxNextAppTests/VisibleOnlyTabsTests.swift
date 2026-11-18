import AppKit
@testable import CmuxNextTabs
import CmuxNextTestSupport
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import QuartzCore
import Testing

/// Leo 2026-11-18 (ask-1105ee4cc6): "we draw the visible area, right? Like, that's what we're supposed to do." The tab
/// strip and the vertical tab list under the visible-rows contract (`VisibleRowsContract`) at 100 and 10,000 tabs, and
/// what windowing must keep: a far tab selected gets its cell, every tab stays an accessibility child in order, and a
/// change to a tab out of view shows when it scrolls in.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct VisibleOnlyTabsTests {
    @Test func tabStrip() async throws {
        try await VisibleRowsContract.check(TabStripRows.self)
    }

    @Test func verticalTabs() async throws {
        try await VisibleRowsContract.check(VerticalTabRows.self)
    }

    @Test(arguments: [100, 10_000])
    func aFarTabStaysReachable(_ count: Int) async throws {
        let f = try await TabStripRows(rows: count)
        defer { f.close() }
        let strip = f.strip, model = f.model
        let alive = strip.rowViewsAlive
        // A change to a tab out of view draws nothing now, and shows once it scrolls in.
        let last = TabID("t\(count - 1)")
        _ = strip.listWork.take()
        model.tabs[count - 1].title = "Far away"
        strip.syncFromModel()
        #expect(strip.listWork.take().rowsConfigured == 0)
        #expect(strip.cells[last] == nil)
        // Selecting it gives it a cell and scrolls to it.
        model.selectedID = last
        strip.syncFromModel()
        CATransaction.flush()
        let cell = try #require(strip.cells[last], "the selected far tab has no cell")
        #expect(cell.isSelected && cell.item.title == "Far away")
        #expect(strip.rowViewsAlive <= alive + 2, "\(strip.rowViewsAlive) cells after the reveal, \(alive) before")
        // Every tab is an accessibility child, in order, the cell's own element where it has one.
        let elements = (strip.accessibilityChildren() ?? []).compactMap { $0 as? TabAccessibilityElement }
        #expect(elements.count == count, "\(elements.count) tab elements for \(count) tabs")
        #expect(elements.last === cell.accessibility)
        #expect(elements.first?.accessibilityIdentifier() == "cmux.tabs.tab.t0")
    }

    /// A wheel step of one row draws the row it brings in, not every row in view, and lays nothing out.
    @Test(arguments: [100, 10_000])
    func aListScrollDrawsOnlyTheRowItReveals(_ count: Int) async throws {
        let f = try await VerticalTabRows(rows: count)
        defer { f.close() }
        let list = f.list
        let pitch = list.metrics.rowHeight + list.metrics.rowSpacing
        f.scroll(by: min(list.maxScrollOffset / 2, 2_000))
        let before = list.scrollOffset
        _ = list.listWork.take()
        f.scroll(by: pitch)
        let work = list.listWork.take()
        #expect(abs(list.scrollOffset - before - pitch) <= 1, "the wheel step scrolled \(list.scrollOffset - before), a row is \(pitch)")
        #expect(work.rowsConfigured <= 2 && work.rowsLaidOut == 0,
                "one row of scroll at n=\(count): \(work), \(f.viewportRows) rows in view")
    }

    @Test(arguments: [100, 10_000])
    func aListChangeRedrawsItsRowAlone(_ count: Int) async throws {
        let f = try await VerticalTabRows(rows: count)
        defer { f.close() }
        let list = f.list, model = f.model
        // No row element before an accessibility client asks; then one per tab, framed where its row is.
        #expect(list.accessibilityRows.isEmpty)
        let elements = (list.accessibilityChildren() ?? []).compactMap { $0 as? TabAccessibilityElement }
        #expect(elements.count == count)
        // A switch and a title change lay nothing out and draw their rows only; the title shows.
        _ = list.listWork.take()
        model.selectedID = TabID("v3")
        list.modelChanged()
        model.tabs[4].title = "Renamed"
        list.modelChanged()
        VerticalTabRows.drawFrame(f.window)
        let work = list.listWork.take()
        #expect(work.rowsLaidOut == 0 && work.rowsConfigured <= 3, "\(work)")
        #expect(list.listLayout.tabs[4].title == "Renamed")
        #expect(elements[4].accessibilityLabel()?.hasPrefix("Renamed") == true)
        // A new tab lays the list out.
        model.tabs.append(TabItem(id: TabID("new"), title: "New"))
        list.modelChanged()
        #expect(list.listLayout.frame(of: TabID("new")) != nil)
    }
}

/// The tab strip over `rows` tabs in a 1400 pt window (from about 30 tabs it scrolls).
@MainActor final class TabStripRows: VisibleRowsFixture {
    static let name = "tab strip"
    let window: NSWindow
    let strip: TabStripView
    let model: TabStripModel
    var list: TabStripView { strip }

    init(rows: Int) async throws {
        _ = NSApplication.shared
        let items = (0..<rows).map { TabItem(id: TabID("t\($0)"), title: "Tab number \($0)") }
        model = TabStripModel(tabs: items, selectedID: items.first?.id)
        strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        strip.frame = NSRect(x: 0, y: 0, width: 1400, height: TabStripView.preferredHeight)
        strip.autoresizingMask = [.width]
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        strip.syncFromModel()
        strip.layoutSubtreeIfNeeded()
        CATransaction.flush()
    }

    var viewportRows: Int {
        let minX = strip.scrollOffset, maxX = minX + strip.viewportWidth
        return strip.result.slots.filter { $0.maxX > minX && $0.x < maxX }.count
    }

    /// A shown tab's title changes, as the App hands the model its tabs.
    func changeOneItem() async throws {
        model.tabs[2].title = "Renamed"
        strip.syncFromModel()
        CATransaction.flush()
    }

    /// From the middle of the row (that move is not measured), one tab further, as a wheel step does.
    func scrollOneRow() async throws -> Bool {
        guard strip.result.isOverflowing, let tab = strip.result.slots.last?.width else { return false }
        scroll(to: (strip.result.contentWidth - strip.viewportWidth) / 2)
        _ = strip.listWork.take()
        scroll(to: strip.scrollOffset + tab)
        return true
    }

    private func scroll(to offset: CGFloat) {
        strip.settleScroll()
        strip.scrollOffset = TabScrollMath.clamp(offset, contentWidth: strip.result.contentWidth, viewportWidth: strip.viewportWidth)
        strip.applyFrames()
        CATransaction.flush()
    }

    /// One live-resize step of the window: 8 pt narrower.
    func resizeOneStep() async throws -> Bool {
        window.setContentSize(NSSize(width: 1392, height: 60))
        strip.layoutSubtreeIfNeeded()
        CATransaction.flush()
        return true
    }

    func close() { window.close() }
}

/// The vertical tab list over `rows` tabs, 600 pt tall.
@MainActor final class VerticalTabRows: VisibleRowsFixture {
    static let name = "vertical tabs"
    let window: NSWindow
    let list: VerticalTabListView
    let model: TabStripModel

    init(rows: Int) async throws {
        _ = NSApplication.shared
        let items = (0..<rows).map { TabItem(id: TabID("v\($0)"), title: "Tab number \($0)") }
        model = TabStripModel(tabs: items, selectedID: items.first?.id)
        list = VerticalTabListView(model: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        list.frame = NSRect(x: 0, y: 0, width: VerticalTabListView.expandedWidth, height: 600)
        window.contentView = list
        window.orderFrontRegardless()
        list.layoutSubtreeIfNeeded()
        list.modelChanged()
        Self.drawFrame(window)
        await Self.settle()
    }

    /// Lays the window out, draws what is dirty and commits, as a display frame does.
    static func drawFrame(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    /// Lets the list's model observation run.
    static func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(100))
    }

    var viewportRows: Int { list.listLayout.rowRange(minY: list.scrollOffset, maxY: list.scrollOffset + list.bounds.height).count }

    /// A shown tab's title changes, as the App hands the model its tabs.
    func changeOneItem() async throws {
        model.tabs[2].title = "Renamed"
        await Self.settle()
        list.modelChanged() // the observation's call, if it has not run: a second finds nothing new
        Self.drawFrame(window)
    }

    /// From the middle of the list (not measured), one row down, as a wheel step does.
    func scrollOneRow() async throws -> Bool {
        guard list.maxScrollOffset > 0 else { return false }
        scroll(by: min(list.maxScrollOffset / 2, 2_000))
        _ = list.listWork.take()
        scroll(by: list.metrics.rowHeight + list.metrics.rowSpacing)
        return true
    }

    /// A precise wheel step of `delta` points down, through the list's own wheel handling, then a display frame.
    func scroll(by delta: CGFloat) {
        list.scrollWheel(with: Self.wheel(by: delta))
        Self.drawFrame(window)
    }

    /// A trackpad-style wheel event scrolling `delta` points down, the pointer away from the list (no hover).
    static func wheel(by delta: CGFloat) -> NSEvent {
        let points = Int32(-delta.rounded())
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: points, wheel2: 0, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(points))
        event.location = CGPoint(x: -10_000, y: -10_000)
        return NSEvent(cgEvent: event)!
    }

    /// The list's widths are fixed (expanded, collapsed).
    func resizeOneStep() async throws -> Bool { false }

    func close() { window.close() }
}
