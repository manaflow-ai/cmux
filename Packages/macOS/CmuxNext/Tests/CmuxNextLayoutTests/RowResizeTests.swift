import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Row divider drags (rows.md Z1) and the model's row intents with their
/// capability and off-switch gates (rows.md O2, step 4).
struct RowResizeTests {
    private let frame = CGRect(x: 0, y: 0, width: 400, height: 600)

    private func rows(_ heights: [Int]) -> [LayoutRow] {
        heights.enumerated().map { LayoutRow(id: RowID("r\($0.offset)"), height: $0.element, root: .leaf(PaneID("p\($0.offset)"))) }
    }

    @Test func filledRowsTradeHeightWithTheRowBelow() {
        let rows = rows([500, 500])
        let stack = RowStackGeometry.compute(column: "c", rows: rows, in: frame, gap: 8, scale: 1)
        let heights = RowResize.heights(rows, stack: stack, upper: "r0", pointerY: 148)
        #expect(heights.map(\.height) == [250, 750])
        #expect(heights.map(\.row) == ["r0", "r1"])
    }

    @Test func scrollingRowsChangeOnlyTheUpperRow() {
        let rows = rows([1000, 600])
        let stack = RowStackGeometry.compute(column: "c", rows: rows, in: frame, gap: 8, scale: 1)
        let heights = RowResize.heights(rows, stack: stack, upper: "r0", pointerY: 296)
        #expect(heights.map(\.height) == [500, 600])
    }

    @Test func aRowKeepsItsFloorAndItsTreesMinimum() {
        let rows = rows([500, 500])
        let stack = RowStackGeometry.compute(column: "c", rows: rows, in: frame, gap: 8, scale: 1)
        #expect(RowResize.heights(rows, stack: stack, upper: "r0", pointerY: -50).map(\.height) == [100, 900])
        let kept = RowResize.heights(rows, stack: stack, upper: "r0", pointerY: 10, minimums: ["r0": 200])
        #expect(kept[0].height > 300)
    }

    @Test func theLastRowHasNoEdge() {
        let rows = rows([500, 500])
        let stack = RowStackGeometry.compute(column: "c", rows: rows, in: frame, gap: 8, scale: 1)
        #expect(RowResize.heights(rows, stack: stack, upper: "r1", pointerY: 10).map(\.height) == [500, 500])
    }
}

@MainActor @Suite struct RowIntentTests {
    private func model(acceptsRowOps: Bool, rowsEnabled: Bool = true) -> (LayoutModel, () -> [LayoutIntent]) {
        let column = LayoutColumn(id: "c", width: 1, root: .split("r2", axis: .vertical, ratio: 0.5, a: .leaf("a"), b: .leaf("b")),
                                  rows: [LayoutRow(id: "r1", height: 1000, root: .leaf("a")), LayoutRow(id: "r2", height: 400, root: .leaf("b"))])
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "1", layout: .columns([column]))])
        model.followsDesignMetrics = false
        model.acceptsRowOps = acceptsRowOps
        model.rowsEnabledOverride = rowsEnabled
        var sent: [LayoutIntent] = []
        model.intentHandler = { sent.append($0) }
        return (model, { sent })
    }

    @Test func rowHeightsAreSentOnlyToARowsDaemonAndOnlyWhole() {
        let heights = [RowHeight(row: "r1", height: 600), RowHeight(row: "r2", height: 400)]
        let (refused, refusedSent) = model(acceptsRowOps: false)
        refused.setRowHeights("c", heights: heights, fit: true)
        #expect(refusedSent().isEmpty)

        let (model, sent) = model(acceptsRowOps: true)
        model.setRowHeights("c", heights: [RowHeight(row: "r1", height: 600)], fit: false)
        model.setRowHeights("c", heights: [RowHeight(row: "r1", height: 50), RowHeight(row: "r2", height: 400)], fit: false)
        model.setRowHeights("c", heights: [RowHeight(row: "r1", height: 700), RowHeight(row: "r2", height: 400)], fit: true)
        #expect(sent().isEmpty)
        model.setRowHeights("c", heights: heights, fit: true)
        #expect(sent() == [.setRowHeights("c", heights: heights, fit: true)])
        #expect(model.screens[0].layout.columns[0].rows.map(\.height) == [1000, 400], "no local copy")
    }

    @Test func newRowNeedsTheCapabilityAndRowsOn() {
        let (missing, missingSent) = model(acceptsRowOps: false)
        #expect(!missing.newRow(below: "a"))
        #expect(missingSent().isEmpty)
        let (off, offSent) = model(acceptsRowOps: true, rowsEnabled: false)
        #expect(!off.newRow(below: "a"))
        #expect(offSent().isEmpty)
        let (model, sent) = model(acceptsRowOps: true)
        #expect(model.newRow(below: "b"))
        #expect(sent() == [.newRow(below: "b", height: 400)], "matchCurrent: the focused row's stored height")
    }

    @Test func aPaneWithoutRowsGetsAFullHeightRow() {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "1", layout: .splits(.leaf("x")))])
        model.followsDesignMetrics = false
        #expect(model.newRowHeight(below: "x") == 1000)
    }
}

/// The rows of a column as a vertical strip behind the `RowScroll`
/// adapter: the column scroll rules reveal the focused row (rows.md V1)
/// and stay put otherwise; strip slots never carry row ids.
struct RowStripTests {
    private let rows = [LayoutRow(id: "r1", height: 1000, root: .leaf("a")), LayoutRow(id: "r2", height: 500, root: .leaf("b"))]

    private func strip(_ scroll: inout RowScroll, rows: [LayoutRow]? = nil) -> ColumnStrip {
        let rows = rows ?? self.rows
        let column = LayoutColumn(id: "c", width: 1, root: .leaf("a"), rows: rows)
        let stack = RowStackGeometry.compute(column: "c", rows: rows, in: CGRect(x: 20, y: 10, width: 400, height: 600), gap: 8, scale: 1)
        var panes: [PaneID: CGRect] = [:]
        for (row, placed) in zip(rows, stack.rows) { for pane in row.root.panes { panes[pane] = placed.frame } }
        return scroll.strip(rows: stack, column: column, panes: panes)
    }

    @Test func rowsBecomeAStripMeasuredFromTheColumnTop() {
        var scroll = RowScroll()
        let strip = strip(&scroll)
        #expect(strip.viewportWidth == 600)
        #expect(strip.contentWidth == 904)
        #expect(strip.columns.map(\.frame.minX) == [0, 608])
        #expect(strip.columns[1].frame.width == 296)
        #expect(strip.index(ofPane: "b") == 1)
        #expect(strip.columns.allSatisfy { !$0.id.rawValue.contains("r1") && !$0.id.rawValue.contains("r2") })
        #expect(scroll.row(forSlot: strip.columns[1].id) == "r2")
    }

    @Test func slotsStayStableWhileARowLivesAndDieWithIt() {
        var scroll = RowScroll()
        let first = strip(&scroll)
        let inserted = [rows[0], LayoutRow(id: "r9", height: 300, root: .leaf("z")), rows[1]]
        let second = strip(&scroll, rows: inserted)
        #expect(second.columns[0].id == first.columns[0].id)
        #expect(second.columns[2].id == first.columns[1].id)
        _ = strip(&scroll, rows: [rows[0], rows[1]])
        #expect(scroll.row(forSlot: second.columns[1].id) == nil)
    }

    @Test func focusingAHiddenRowRevealsItAndBackKeepsTheCamera() {
        var scroll = RowScroll()
        var current = strip(&scroll)
        scroll.state.reduce(.sync(current, focused: "a", source: .programmatic, animated: false))
        #expect(scroll.state.spring.value == 0)
        current = strip(&scroll)
        scroll.state.reduce(.sync(current, focused: "b", source: .keyboard, animated: false))
        #expect(scroll.state.spring.value == 304, "the bottom row aligns with the column's bottom edge")
        current = strip(&scroll)
        scroll.state.reduce(.sync(current, focused: nil, source: .keyboard, animated: false))
        #expect(scroll.state.spring.value == 304, "focus elsewhere does not move the rows")
    }
}
