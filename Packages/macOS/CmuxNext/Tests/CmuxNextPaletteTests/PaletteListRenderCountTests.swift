import AppKit
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-18: "we draw the visible area, right?" The palette's result list per keystroke:
/// a results update configures only the mounted rows whose content changed, and the table asks
/// no height of a row it kept, at 100 results as at 10,000. Each case prints its counts
/// ("palette-list-counts").
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaletteListRenderCountTests {
    struct Harness {
        let list: PaletteListView
        let window: NSWindow
        var table: NSTableView { list.table }

        func show(_ rows: [PaletteRow]) {
            list.setSections(PaletteListRenderCountTests.sections(rows))
            settle()
        }

        func settle() {
            list.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        /// The mounted rows' text, by row, against what `rows` lists there.
        func expectMountedRows(match rows: [PaletteRow], sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(table.numberOfRows == rows.count + 1, sourceLocation: sourceLocation)
            table.enumerateAvailableRowViews { _, row in
                let view = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                if row == 0 {
                    #expect((view as? PaletteSectionHeaderCell)?.title == "Results", sourceLocation: sourceLocation)
                } else {
                    #expect((view as? PaletteRowCell)?.accessibilityLabel() == rows[row - 1].item.title, "row \(row)",
                            sourceLocation: sourceLocation)
                }
            }
        }
    }

    static func row(_ i: Int, title: String? = nil) -> PaletteRow {
        let item = PaletteItem(id: "item\(i)", title: title ?? "Row \(i)",
                               primary: PaletteCommand(id: "run", title: "Run", effect: .perform {}))
        return PaletteRow(item: item, highlights: [], score: 0)
    }

    static func rows(_ count: Int) -> [PaletteRow] { (0..<count).map { row($0) } }

    static func sections(_ rows: [PaletteRow]) -> [PaletteResultSection] {
        [PaletteResultSection(section: PaletteSection(id: "results", title: "Results", order: 0), rows: rows)]
    }

    static func make(_ count: Int) -> Harness {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 600, height: PaletteLayout.listHeight)
        let window = NSWindow(contentRect: frame.offsetBy(dx: 100, dy: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let list = PaletteListView(frame: frame)
        window.contentView = list
        list.frame = frame
        window.orderFrontRegardless()
        let harness = Harness(list: list, window: window)
        harness.show(rows(count))
        list.resetCounts()
        return harness
    }

    /// Rows a viewport shows, with a row's overscan on each side.
    static var viewportBound: Int { Int(PaletteLayout.visibleRows) * 3 + 2 }

    static func report(_ name: String, _ count: Int, _ harness: Harness) {
        let c = harness.list.counts
        print("palette-list-counts N=\(count) \(name): configures=\(c.configures) heights=\(c.heights) mounted=\(harness.list.mountedRowCount)")
    }

    @Test(arguments: [100, 10_000])
    func mountedRowsStayWithinTheViewport(count: Int) {
        let harness = Self.make(count)
        defer { harness.window.close() }
        Self.report("mounted", count, harness)
        #expect(harness.list.mountedRowCount <= Self.viewportBound)
        harness.expectMountedRows(match: Self.rows(count))
    }

    /// A keystroke whose results draw the same (a new version of the same rows) configures no row.
    @Test(arguments: [100, 10_000])
    func sameResultsConfigureNoRow(count: Int) {
        let harness = Self.make(count)
        defer { harness.window.close() }
        harness.show(Self.rows(count))
        Self.report("same-results", count, harness)
        #expect(harness.list.counts.configures == 0)
        #expect(harness.list.counts.heights == 0)
    }

    /// One visible row's content changes: that row alone is configured.
    @Test(arguments: [100, 10_000])
    func oneChangedRowConfiguresOneRow(count: Int) {
        let harness = Self.make(count)
        defer { harness.window.close() }
        var rows = Self.rows(count)
        rows[2] = Self.row(2, title: "Row 2 changed")
        harness.show(rows)
        Self.report("one-changed", count, harness)
        #expect(harness.list.counts.configures == 1)
        #expect(harness.list.counts.heights == 0)
        harness.expectMountedRows(match: rows)
    }

    /// Typing drops the first result: the rows below move up as they are, and only the row the
    /// move reveals is configured; no height is asked for every row.
    @Test(arguments: [100, 10_000])
    func droppingTheFirstRowConfiguresOnlyTheRevealedRow(count: Int) {
        let harness = Self.make(count)
        defer { harness.window.close() }
        let rows = Array(Self.rows(count).dropFirst())
        harness.show(rows)
        Self.report("drop-first", count, harness)
        #expect(harness.list.counts.configures <= 2)
        #expect(harness.list.counts.heights <= 2)
        harness.expectMountedRows(match: rows)
    }

    /// Two visible rows trade places: the moved rows alone are configured.
    @Test(arguments: [100, 10_000])
    func reorderedRowsConfigureOnlyTheMovedRows(count: Int) {
        let harness = Self.make(count)
        defer { harness.window.close() }
        var rows = Self.rows(count)
        rows.swapAt(1, 3)
        harness.show(rows)
        Self.report("swap-two", count, harness)
        #expect(harness.list.counts.configures <= 2)
        harness.expectMountedRows(match: rows)
    }

    /// A query that keeps every other result, in reverse, still lists exactly the new rows.
    @Test(arguments: [100, 10_000])
    func aReshuffledResultListsTheNewRows(count: Int) {
        let harness = Self.make(count)
        defer { harness.window.close() }
        let rows = Self.rows(count).enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element).reversed()
            + [Self.row(count + 1)]
        harness.show(Array(rows))
        Self.report("reshuffle", count, harness)
        #expect(harness.list.mountedRowCount <= Self.viewportBound)
        harness.expectMountedRows(match: Array(rows))
    }

    /// One scroll step configures only the rows it reveals.
    @Test(arguments: [100, 10_000])
    func oneScrollStepConfiguresOnlyRevealedRows(count: Int) {
        let harness = Self.make(count)
        defer { harness.window.close() }
        let clip = harness.list.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + PaletteLayout.rowHeight))
        harness.list.reflectScrolledClipView(clip)
        harness.settle()
        Self.report("scroll-step", count, harness)
        #expect(harness.list.counts.configures <= 2)
        #expect(harness.list.mountedRowCount <= Self.viewportBound)
    }

    /// Selection follows the row's id through a results update, and a selection change configures no row.
    @Test(arguments: [100, 10_000])
    func selectionFollowsTheRowAndConfiguresNothing(count: Int) {
        let harness = Self.make(count)
        defer { harness.window.close() }
        harness.list.setSelection("item5")
        harness.list.setSelection("item6")
        #expect(harness.list.counts.configures == 0)
        harness.show(Array(Self.rows(count).dropFirst()))
        // The header, then item1...: item6 is row 6.
        #expect(harness.table.selectedRow == 6)
    }

    /// A window size change that keeps every row height asks no height.
    @Test(arguments: [100, 10_000])
    func relayoutWithSameHeightsAsksNoHeight(count: Int) {
        let harness = Self.make(count)
        defer { harness.window.close() }
        harness.list.relayoutRows()
        harness.settle()
        Self.report("relayout", count, harness)
        #expect(harness.list.counts.heights == 0)
    }
}
