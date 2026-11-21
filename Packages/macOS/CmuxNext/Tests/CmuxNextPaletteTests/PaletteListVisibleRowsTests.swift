import AppKit
@testable import CmuxNextPalette
import CmuxNextTestSupport
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import QuartzCore
import Testing

/// Leo 2026-11-18 (ask-1105ee4cc6): "we draw the visible area, right? Like, that's what we're supposed to do." The
/// palette's result list per keystroke, at 100 and 10,000 results: the visible-rows contract, and the keystrokes
/// typing makes (the same results again, one row dropped, two rows trading places), each configuring only the
/// mounted rows whose content changed and asking no height of a row the table kept. Each case prints its counts
/// ("palette-list-work").
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct PaletteListVisibleRowsTests {
    @Test func visibleRows() async throws {
        try await VisibleRowsContract.check(PaletteListRows.self)
    }

    static func report(_ name: String, _ n: Int, _ work: ListWorkMeter.Reading) {
        print("palette-list-work n=\(n) \(name): \(work)")
    }

    /// A keystroke whose results draw the same (a new version of the same rows) configures no row and asks no height.
    @Test(arguments: [100, 10_000])
    func sameResultsConfigureNoRow(n: Int) async throws {
        let f = try await PaletteListRows(rows: n)
        defer { f.close() }
        _ = f.list.listWork.take()
        f.show(PaletteListRows.rows(n))
        let work = f.list.listWork.take()
        Self.report("same-results", n, work)
        #expect(work.rowsConfigured == 0)
        #expect(work.rowsLaidOut == 0)
    }

    /// Typing drops the first result: the rows below move up as they are; only the row the move reveals is
    /// configured, and only its height is asked.
    @Test(arguments: [100, 10_000])
    func droppingTheFirstRowConfiguresOnlyTheRevealedRow(n: Int) async throws {
        let f = try await PaletteListRows(rows: n)
        defer { f.close() }
        _ = f.list.listWork.take()
        let rows = Array(PaletteListRows.rows(n).dropFirst())
        f.show(rows)
        let work = f.list.listWork.take()
        Self.report("drop-first", n, work)
        #expect(work.rowsConfigured <= 2)
        #expect(work.rowsLaidOut <= 2)
        f.expectMountedRows(match: rows)
    }

    /// Two shown rows trade places: the moved rows alone are configured.
    @Test(arguments: [100, 10_000])
    func reorderedRowsConfigureOnlyTheMovedRows(n: Int) async throws {
        let f = try await PaletteListRows(rows: n)
        defer { f.close() }
        _ = f.list.listWork.take()
        var rows = PaletteListRows.rows(n)
        rows.swapAt(1, 3)
        f.show(rows)
        let work = f.list.listWork.take()
        Self.report("swap-two", n, work)
        #expect(work.rowsConfigured <= 2)
        f.expectMountedRows(match: rows)
    }

    /// A query that keeps every other result, reversed, plus a new one, lists exactly the new rows.
    @Test(arguments: [100, 10_000])
    func aReshuffledResultListsTheNewRows(n: Int) async throws {
        let f = try await PaletteListRows(rows: n)
        defer { f.close() }
        let rows = PaletteListRows.rows(n).enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element).reversed()
            + [PaletteListRows.row(n + 1)]
        f.show(rows)
        f.expectMountedRows(match: rows)
    }

    /// Selection follows the row's id through a results update, and a selection change configures no row.
    @Test(arguments: [100, 10_000])
    func selectionFollowsTheRowAndConfiguresNothing(n: Int) async throws {
        let f = try await PaletteListRows(rows: n)
        defer { f.close() }
        _ = f.list.listWork.take()
        f.list.setSelection("item5")
        f.list.setSelection("item6")
        #expect(f.list.listWork.take().rowsConfigured == 0)
        f.show(Array(PaletteListRows.rows(n).dropFirst()))
        // The header, then item1...: item6 is row 6.
        #expect(f.list.table.selectedRow == 6)
    }

    /// Typing over 10,000 results: each keystroke's new results reach the list and draw (set, lay out, display,
    /// commit), and the p95 of that main-thread time fits one 60 Hz frame (16 ms). The keystrokes narrow and widen
    /// the results as typing and backspacing do. Ranking runs off the main thread and is not counted here.
    @Test func typingOver10000ResultsFitsAFrame() async throws {
        let n = 10_000
        let f = try await PaletteListRows(rows: n)
        defer { f.close() }
        let all = PaletteListRows.rows(n)
        var samples: [Double] = []
        let clock = ContinuousClock()
        for key in 0..<80 {
            // Narrow by a few rows, then back out, with one shown row's highlight changing.
            let dropped = key % 8 < 4 ? key % 8 : 8 - key % 8
            var rows = Array(all.dropFirst(dropped))
            rows[0] = PaletteRow(item: rows[0].item, highlights: [key % 3], score: 0)
            let elapsed = clock.measure { f.show(rows) }
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3)
        }
        samples.sort()
        let p95 = samples[Int(Double(samples.count) * 0.95) - 1]
        let median = samples[samples.count / 2]
        print("palette-list-frame n=\(n) keystrokes=\(samples.count) median=\(String(format: "%.2f", median)) ms "
            + "p95=\(String(format: "%.2f", p95)) ms max=\(String(format: "%.2f", samples.last ?? 0)) ms")
        #expect(p95 <= 16, "p95 \(p95) ms per keystroke over \(n) results: over one frame")
    }

    /// A panel size change that keeps every row height asks no height.
    @Test(arguments: [100, 10_000])
    func relayoutWithSameHeightsAsksNoHeight(n: Int) async throws {
        let f = try await PaletteListRows(rows: n)
        defer { f.close() }
        _ = f.list.listWork.take()
        f.list.relayoutRows()
        f.draw()
        let work = f.list.listWork.take()
        Self.report("relayout", n, work)
        #expect(work.rowsLaidOut == 0)
    }
}

/// The palette's result list over `rows` results under one section title, in a window the palette's list size.
@MainActor final class PaletteListRows: VisibleRowsFixture {
    static let name = "command palette results"
    let list: PaletteListView
    let window: NSWindow
    let count: Int

    init(rows count: Int) async throws {
        _ = NSApplication.shared
        self.count = count
        let frame = NSRect(x: 0, y: 0, width: 600, height: PaletteLayout.listHeight)
        window = NSWindow(contentRect: frame.offsetBy(dx: 100, dy: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        list = PaletteListView(frame: frame)
        window.contentView = list
        list.frame = frame
        window.orderFrontRegardless()
        show(Self.rows(count))
    }

    static func row(_ i: Int, title: String? = nil) -> PaletteRow {
        let item = PaletteItem(id: "item\(i)", title: title ?? "Row \(i)", primary: PaletteCommand(id: "run", title: "Run", effect: .perform {}))
        return PaletteRow(item: item, highlights: [], score: 0)
    }

    static func rows(_ count: Int) -> [PaletteRow] { (0..<count).map { row($0) } }

    /// New results, as `PaletteContentView.render` hands them on a results version, then a frame.
    func show(_ rows: [PaletteRow]) {
        list.setSections([PaletteResultSection(section: PaletteSection(id: "results", title: "Results", order: 0), rows: rows)])
        draw()
    }

    func draw() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    var viewportRows: Int {
        let range = list.table.rows(in: list.table.visibleRect)
        return range.length
    }

    /// One shown result's title changes (a new version of the results with that row renamed).
    func changeOneItem() async throws {
        var rows = Self.rows(count)
        rows[2] = Self.row(2, title: "Row 2 changed")
        show(rows)
    }

    /// From the middle of the list (that move is not measured), one row down.
    func scrollOneRow() async throws -> Bool {
        let clip = list.contentView
        let maxY = max(0, list.table.frame.height - clip.bounds.height)
        guard maxY > 0 else { return false }
        scroll(to: min(maxY / 2, 2_000))
        _ = list.listWork.take()
        scroll(to: clip.bounds.minY + PaletteLayout.rowHeight)
        return true
    }

    private func scroll(to y: CGFloat) {
        let clip = list.contentView
        clip.scroll(to: NSPoint(x: 0, y: y))
        list.reflectScrolledClipView(clip)
        draw()
    }

    /// The palette panel is a fixed size (`PaletteLayout.windowSize`); a size setting change is `relayoutRows`.
    func resizeOneStep() async throws -> Bool { false }

    func close() { window.close() }

    /// The mounted rows' text, by row, against what `rows` lists there.
    func expectMountedRows(match rows: [PaletteRow], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(list.table.numberOfRows == rows.count + 1, sourceLocation: sourceLocation)
        list.table.enumerateAvailableRowViews { _, row in
            let view = list.table.view(atColumn: 0, row: row, makeIfNecessary: false)
            if row == 0 {
                #expect((view as? PaletteSectionHeaderCell)?.title == "Results", sourceLocation: sourceLocation)
            } else {
                #expect((view as? PaletteRowCell)?.accessibilityLabel() == rows[row - 1].item.title, "row \(row)",
                        sourceLocation: sourceLocation)
            }
        }
    }
}
