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

/// The rows of a column as a vertical strip: the column scroll rules
/// reveal the focused row (rows.md V1) and stay put otherwise.
struct RowStripTests {
    private func strip() -> ColumnStrip {
        let rows = [LayoutRow(id: "r1", height: 1000, root: .leaf("a")), LayoutRow(id: "r2", height: 500, root: .leaf("b"))]
        let column = LayoutColumn(id: "c", width: 1, root: .split("r2", axis: .vertical, ratio: 0.6, a: .leaf("a"), b: .leaf("b")), rows: rows)
        let stack = RowStackGeometry.compute(column: "c", rows: rows, in: CGRect(x: 20, y: 10, width: 400, height: 600), gap: 8, scale: 1)
        let panes: [PaneID: CGRect] = ["a": stack.rows[0].frame, "b": stack.rows[1].frame]
        return ColumnStrip(rows: stack, column: column, panes: panes)
    }

    @Test func rowsBecomeAStripMeasuredFromTheColumnTop() {
        let strip = strip()
        #expect(strip.viewportWidth == 600)
        #expect(strip.contentWidth == 904)
        #expect(strip.columns.map(\.frame.minX) == [0, 608])
        #expect(strip.columns[1].frame.width == 296)
        #expect(strip.index(ofPane: "b") == 1)
    }

    @Test func focusingAHiddenRowRevealsItAndBackKeepsTheCamera() {
        var state = ColumnScrollState()
        state.reduce(.sync(strip(), focused: "a", source: .programmatic, animated: false))
        #expect(state.spring.value == 0)
        state.reduce(.sync(strip(), focused: "b", source: .keyboard, animated: false))
        #expect(state.spring.value == 304, "the bottom row aligns with the column's bottom edge")
        state.reduce(.sync(strip(), focused: nil, source: .keyboard, animated: false))
        #expect(state.spring.value == 304, "focus elsewhere does not move the rows")
    }
}
