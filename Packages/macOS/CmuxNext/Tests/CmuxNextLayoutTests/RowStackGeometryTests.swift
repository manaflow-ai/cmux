import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Rows inside a column (plans/cmux-next/rows.md G1, G2, O3, O4).
struct RowStackGeometryTests {
    private let frame = CGRect(x: 10, y: 0, width: 400, height: 600)
    private let gap: CGFloat = 8

    private func rows(_ heights: [Int]) -> [LayoutRow] {
        heights.enumerated().map { LayoutRow(id: RowID("r\($0.offset)"), height: $0.element, root: .leaf(PaneID("p\($0.offset)"))) }
    }

    @Test func rowsSummingToOneThousandFillTheColumn() {
        let stack = RowStackGeometry.compute(column: "c", rows: rows([500, 500]), in: frame, gap: gap, scale: 1)
        #expect(!stack.scrolls)
        #expect(stack.rows[0].frame == CGRect(x: 10, y: 0, width: 400, height: 296))
        #expect(stack.rows[1].frame == CGRect(x: 10, y: 304, width: 400, height: 296))
        #expect(stack.contentHeight == 600)
    }

    @Test func rowsSummingBelowOneThousandFillInProportion() {
        let stack = RowStackGeometry.compute(column: "c", rows: rows([200, 600]), in: frame, gap: gap, scale: 1)
        #expect(!stack.scrolls)
        #expect(stack.rows[0].frame.height == 144)
        #expect(stack.rows[1].frame.maxY == 600)
    }

    @Test func rowsSummingAboveOneThousandKeepTheirHeightsAndScroll() {
        let stack = RowStackGeometry.compute(column: "c", rows: rows([1000, 500]), in: frame, gap: gap, scale: 1)
        #expect(stack.scrolls)
        #expect(stack.rows[0].frame.height == 600, "a full-height row is today's column")
        #expect(stack.rows[1].frame == CGRect(x: 10, y: 608, width: 400, height: 296))
        #expect(stack.maxOffset == 304)
    }

    /// O3: rows turned off fit the column like stacked panes, never scrolling.
    @Test func rowsOffFitTheColumn() {
        let stack = RowStackGeometry.compute(column: "c", rows: rows([1000, 500]), in: frame, gap: gap, fits: true, scale: 1)
        #expect(!stack.scrolls)
        #expect(stack.rows[1].frame.maxY == 600)
        #expect(abs(stack.rows[0].frame.height - 2 * stack.rows[1].frame.height) <= 9)
    }

    @Test func aRowKeepsTheHeightItsTreeNeeds() {
        let stack = RowStackGeometry.compute(column: "c", rows: rows([1000, 100]), minimumHeights: [0, 120], in: frame, gap: gap, scale: 1)
        #expect(stack.rows[1].frame.height == 120)
    }

    @Test func permilleRoundTripsThroughPixels() {
        for permille in [100, 250, 333, 500, 1000] {
            let pixels = RowStackGeometry.pixelHeight(permille: Double(permille), columnHeight: 600, gap: gap)
            #expect(RowStackGeometry.permille(forPixelHeight: pixels, columnHeight: 600, gap: gap) == permille)
        }
        #expect(RowStackGeometry.permille(forPixelHeight: 1, columnHeight: 600, gap: gap) == 100)
        #expect(RowStackGeometry.permille(forPixelHeight: 5000, columnHeight: 600, gap: gap) == 1000)
    }

    @Test func edgesSitInTheGaps() {
        let stack = RowStackGeometry.compute(column: "c", rows: rows([500, 500]), in: frame, gap: gap, scale: 1)
        let edges = stack.edges(thickness: 10)
        #expect(edges.count == 1)
        #expect(edges[0].upper == "r0" && edges[0].lower == "r1")
        #expect(edges[0].hitFrame == CGRect(x: 10, y: 295, width: 400, height: 10))
    }
}

/// Rows in a whole screen's geometry: panes sit in their rows, the column's
/// vertical offset moves only its own content, and a screen without rows is
/// identical with rows on and off (O4).
struct ScreenRowGeometryTests {
    private let viewport = CGSize(width: 1200, height: 800)

    private var layout: ScreenLayout {
        let rows = [LayoutRow(id: "r1", height: 1000, root: .leaf("a")),
                    LayoutRow(id: "r2", height: 500, root: .split("s", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))]
        let chain = SplitNode.split("r2", axis: .vertical, ratio: 0.66, a: .leaf("a"), b: rows[1].root)
        return .columns([LayoutColumn(id: "c1", width: 0.5, root: chain, rows: rows), LayoutColumn(id: "c2", width: 0.5, root: .leaf("d"))])
    }

    @Test func panesSitInTheirRows() throws {
        let geometry = ScreenGeometry.compute(layout, viewport: viewport, style: LayoutStyle(), scale: 1)
        let stack = try #require(geometry.rowStacks["c1"])
        #expect(stack.scrolls)
        #expect(geometry.panes["a"] == stack.rows[0].frame)
        let b = try #require(geometry.panes["b"])
        #expect(b.minY == stack.rows[1].frame.minY)
        #expect(geometry.rowEdges.map(\.upper) == ["r1"])
        #expect(geometry.rowColumnOfPane["c"] == "c1")
        #expect(geometry.rowColumnOfPane["d"] == nil)
        #expect(geometry.dividers.map(\.id) == ["s"], "the compat chain's row split draws no divider")
        #expect(geometry.rowColumnOfSplit["s"] == "c1")
    }

    @Test func aVerticalOffsetMovesOnlyItsColumn() {
        let geometry = ScreenGeometry.compute(layout, viewport: viewport, style: LayoutStyle(), scale: 1)
        let shifted = geometry.shiftingRows(["c1": 100])
        #expect(shifted.panes["a"] == geometry.panes["a"]?.offsetBy(dx: 0, dy: -100))
        #expect(shifted.panes["d"] == geometry.panes["d"])
        #expect(shifted.dividers[0].frame == geometry.dividers[0].frame.offsetBy(dx: 0, dy: -100))
        #expect(shifted.rowEdges[0].hitFrame == geometry.rowEdges[0].hitFrame.offsetBy(dx: 0, dy: -100))
        #expect(shifted.columns == geometry.columns)
    }

    @Test func aScreenWithoutRowsIsTheSameWithRowsOnAndOff() {
        var off = LayoutStyle()
        off.rowsEnabled = false
        let plain: ScreenLayout = .columns([LayoutColumn(id: "c1", width: 0.6, root: .split("s", axis: .vertical, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))),
                                            LayoutColumn(id: "c2", width: 0.7, root: .leaf("c"))])
        for layout in [plain, .splits(.leaf("x"))] {
            #expect(ScreenGeometry.compute(layout, viewport: viewport, style: LayoutStyle(), scale: 2)
                    == ScreenGeometry.compute(layout, viewport: viewport, style: off, scale: 2))
        }
    }
}
