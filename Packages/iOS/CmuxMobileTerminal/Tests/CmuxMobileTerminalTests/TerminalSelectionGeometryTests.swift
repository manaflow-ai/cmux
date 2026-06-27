#if canImport(UIKit)
import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// Pure-math coverage for the drag-selection cell↔rect and anchor/focus↔range
/// logic. No surface, window, or simulator interaction — only the geometry the
/// overlay and the local text read both depend on.
@Suite("Terminal drag-selection geometry")
struct TerminalSelectionGeometryTests {
    /// 80×24 grid, 8×16pt cells, render origin offset to prove the offset is
    /// carried into every rect (not assumed to be zero).
    private static let geometry = TerminalSelectionCellGeometry(
        origin: CGPoint(x: 10, y: 20),
        cellWidth: 8,
        cellHeight: 16,
        columns: 80,
        rows: 24
    )

    private func cell(_ col: Int, _ row: Int) -> TerminalGridCell {
        TerminalGridCell(col: col, row: row)
    }

    // MARK: reading-order

    @Test("reading order compares row-major")
    func precedesOrEqual() {
        #expect(TerminalSelectionGeometry.precedesOrEqual(cell(5, 1), cell(2, 2)))   // earlier row wins
        #expect(!TerminalSelectionGeometry.precedesOrEqual(cell(2, 2), cell(5, 1)))
        #expect(TerminalSelectionGeometry.precedesOrEqual(cell(2, 1), cell(5, 1)))   // same row, by col
        #expect(!TerminalSelectionGeometry.precedesOrEqual(cell(5, 1), cell(2, 1)))
        #expect(TerminalSelectionGeometry.precedesOrEqual(cell(3, 1), cell(3, 1)))   // equal
    }

    // MARK: clamping

    @Test("clamp pins a cell into the grid bounds")
    func clampInBounds() {
        #expect(
            TerminalSelectionGeometry.clamp(cell(-3, -1), columns: 80, rows: 24) == cell(0, 0)
        )
        #expect(
            TerminalSelectionGeometry.clamp(cell(200, 100), columns: 80, rows: 24) == cell(79, 23)
        )
        #expect(
            TerminalSelectionGeometry.clamp(cell(40, 12), columns: 80, rows: 24) == cell(40, 12)
        )
    }

    @Test("clamp collapses a zero-size grid to the origin cell")
    func clampZeroGrid() {
        #expect(TerminalSelectionGeometry.clamp(cell(5, 5), columns: 0, rows: 0) == cell(0, 0))
    }

    // MARK: ordered range

    @Test("normalizedRange orders and clamps anchor/focus")
    func normalizedRangeOrders() {
        // Forward single row.
        var range = TerminalSelectionGeometry.normalizedRange(
            anchor: cell(2, 1), focus: cell(5, 1), columns: 80, rows: 24
        )
        #expect(range.start == cell(2, 1) && range.end == cell(5, 1))

        // Backward same row → swapped.
        range = TerminalSelectionGeometry.normalizedRange(
            anchor: cell(5, 1), focus: cell(2, 1), columns: 80, rows: 24
        )
        #expect(range.start == cell(2, 1) && range.end == cell(5, 1))

        // Backward multi-row → swapped into reading order.
        range = TerminalSelectionGeometry.normalizedRange(
            anchor: cell(10, 5), focus: cell(3, 2), columns: 80, rows: 24
        )
        #expect(range.start == cell(3, 2) && range.end == cell(10, 5))

        // Out-of-bounds endpoints clamp before ordering.
        range = TerminalSelectionGeometry.normalizedRange(
            anchor: cell(-3, -1), focus: cell(200, 100), columns: 80, rows: 24
        )
        #expect(range.start == cell(0, 0) && range.end == cell(79, 23))
    }

    // MARK: rects — single row

    @Test("single-row selection is one inclusive rect")
    func singleRowRect() {
        let rects = TerminalSelectionGeometry.selectionRects(
            anchor: cell(2, 1), focus: cell(5, 1), geometry: Self.geometry
        )
        // x = 10 + 2*8 = 26, y = 20 + 1*16 = 36, w = (5-2+1)*8 = 32, h = 16
        #expect(rects == [CGRect(x: 26, y: 36, width: 32, height: 16)])
    }

    @Test("a reversed single-row drag yields the same rect")
    func reversedSingleRowRect() {
        let forward = TerminalSelectionGeometry.selectionRects(
            anchor: cell(2, 1), focus: cell(5, 1), geometry: Self.geometry
        )
        let reversed = TerminalSelectionGeometry.selectionRects(
            anchor: cell(5, 1), focus: cell(2, 1), geometry: Self.geometry
        )
        #expect(forward == reversed)
    }

    @Test("a single-cell selection is one cell-sized rect")
    func singleCellRect() {
        let rects = TerminalSelectionGeometry.selectionRects(
            anchor: cell(4, 3), focus: cell(4, 3), geometry: Self.geometry
        )
        // x = 10 + 4*8 = 42, y = 20 + 3*16 = 68, w = 8, h = 16
        #expect(rects == [CGRect(x: 42, y: 68, width: 8, height: 16)])
    }

    // MARK: rects — two rows (partial first, partial last)

    @Test("two-row selection: first row runs to line end, last from line start")
    func twoRowRects() {
        let rects = TerminalSelectionGeometry.selectionRects(
            anchor: cell(78, 1), focus: cell(3, 2), geometry: Self.geometry
        )
        #expect(rects.count == 2)
        // First row 1, cols [78,79]: x = 10 + 78*8 = 634, w = 2*8 = 16
        #expect(rects[0] == CGRect(x: 634, y: 36, width: 16, height: 16))
        // Last row 2, cols [0,3]: x = 10, y = 52, w = 4*8 = 32
        #expect(rects[1] == CGRect(x: 10, y: 52, width: 32, height: 16))
    }

    // MARK: rects — three rows (middle row spans full width)

    @Test("three-row selection: intermediate row spans the full grid width")
    func threeRowRects() {
        let rects = TerminalSelectionGeometry.selectionRects(
            anchor: cell(5, 1), focus: cell(2, 3), geometry: Self.geometry
        )
        #expect(rects.count == 3)
        // First row 1, [5,79]: x = 10 + 5*8 = 50, w = (79-5+1)*8 = 600
        #expect(rects[0] == CGRect(x: 50, y: 36, width: 600, height: 16))
        // Middle row 2, [0,79]: x = 10, y = 52, w = 80*8 = 640 (full width)
        #expect(rects[1] == CGRect(x: 10, y: 52, width: 640, height: 16))
        // Last row 3, [0,2]: x = 10, y = 68, w = 3*8 = 24
        #expect(rects[2] == CGRect(x: 10, y: 68, width: 24, height: 16))
    }

    @Test("middle rows are all full-width and contiguous in y")
    func tallSelectionFullWidthMiddle() {
        let rects = TerminalSelectionGeometry.selectionRects(
            anchor: cell(4, 2), focus: cell(7, 6), geometry: Self.geometry
        )
        // rows 2..6 inclusive = 5 rects
        #expect(rects.count == 5)
        // The 3 interior rows (3,4,5) are each full grid width.
        for interior in rects[1...3] {
            #expect(interior.minX == 10)
            #expect(interior.width == 640)
        }
        // Rows advance by exactly one cell height with no gaps/overlap.
        for index in 1..<rects.count {
            #expect(rects[index].minY == rects[index - 1].minY + 16)
        }
    }

    // MARK: rects — clamping into rects

    @Test("an off-grid drag clamps to a full-screen selection")
    func clampedSelectionRects() {
        let rects = TerminalSelectionGeometry.selectionRects(
            anchor: cell(-5, -5), focus: cell(999, 999), geometry: Self.geometry
        )
        // Whole 24-row grid selected; every row full width.
        #expect(rects.count == 24)
        #expect(rects.first == CGRect(x: 10, y: 20, width: 640, height: 16))
        #expect(rects.last == CGRect(x: 10, y: 20 + 23 * 16, width: 640, height: 16))
    }

    // MARK: point→cell is the exact inverse of cell→rect

    /// The drift bug was a point→cell hit-test and a cell→rect highlight that
    /// used different cell sizes / origins. These pin the contract that they are
    /// inverses: a point anywhere inside cell `c`'s rect hit-tests back to `c`,
    /// and the rect's top-left is exactly `origin + (col·cellW, row·cellH)`.
    @Test("a point inside a cell's rect hit-tests back to that cell")
    func cellAtIsInverseOfRect() {
        for (col, row) in [(0, 0), (1, 0), (7, 3), (40, 12), (79, 23)] {
            let target = cell(col, row)
            let rect = TerminalSelectionGeometry.selectionRects(
                anchor: target, focus: target, geometry: Self.geometry
            )[0]
            // Rect top-left is the exact cell→pixel mapping (no padding/stride drift).
            #expect(rect.minX == Self.geometry.origin.x + CGFloat(col) * Self.geometry.cellWidth)
            #expect(rect.minY == Self.geometry.origin.y + CGFloat(row) * Self.geometry.cellHeight)
            // A point anywhere inside the rect maps back to the cell.
            let inside = CGPoint(x: rect.midX, y: rect.midY)
            #expect(TerminalSelectionGeometry.cell(at: inside, geometry: Self.geometry) == target)
            // The left/top edge belongs to this cell (half-open box).
            let corner = CGPoint(x: rect.minX, y: rect.minY)
            #expect(TerminalSelectionGeometry.cell(at: corner, geometry: Self.geometry) == target)
        }
    }

    @Test("the hit-test floors within a cell — no half-cell boundary drift")
    func cellAtFloorsAtCellBoundary() {
        let col5 = cell(5, 1)
        let rect = TerminalSelectionGeometry.selectionRects(
            anchor: col5, focus: col5, geometry: Self.geometry
        )[0]
        // Just inside the right edge is still col 5; the edge itself is col 6.
        #expect(
            TerminalSelectionGeometry.cell(
                at: CGPoint(x: rect.maxX - 0.01, y: rect.midY), geometry: Self.geometry
            ).col == 5
        )
        #expect(
            TerminalSelectionGeometry.cell(
                at: CGPoint(x: rect.maxX, y: rect.midY), geometry: Self.geometry
            ).col == 6
        )
    }

    @Test("points left of / above the grid clamp to col/row 0")
    func cellAtClampsBelowOrigin() {
        let aboveLeft = CGPoint(x: Self.geometry.origin.x - 100, y: Self.geometry.origin.y - 100)
        #expect(TerminalSelectionGeometry.cell(at: aboveLeft, geometry: Self.geometry) == cell(0, 0))
    }
}
#endif
