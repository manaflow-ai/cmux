import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxHive

@Suite struct HiveTerminalGridModelTests {
    private func fullFrame(
        columns: Int = 10,
        rows: Int = 4,
        stateSeq: UInt64 = 1,
        rowSpans: [MobileTerminalRenderGridFrame.RowSpan]? = nil
    ) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: "surface-1",
            stateSeq: stateSeq,
            columns: columns,
            rows: rows,
            cursor: .init(row: 1, column: 7),
            full: true,
            styles: [
                .init(id: 0),
                .init(id: 1, foreground: "#ff0000", bold: true),
            ],
            rowSpans: rowSpans ?? [
                .init(row: 0, column: 0, styleID: 0, text: "hello"),
                .init(row: 1, column: 2, styleID: 1, text: "world"),
            ],
            terminalForeground: "#ffffff",
            terminalBackground: "#000000"
        )
    }

    private func deltaFrame(
        columns: Int = 10,
        rows: Int = 4,
        stateSeq: UInt64 = 2,
        clearedRows: [Int] = [],
        rowSpans: [MobileTerminalRenderGridFrame.RowSpan] = [],
        cursor: MobileTerminalRenderGridFrame.Cursor? = nil
    ) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: "surface-1",
            stateSeq: stateSeq,
            columns: columns,
            rows: rows,
            cursor: cursor,
            full: false,
            clearedRows: clearedRows,
            styles: [.init(id: 0)],
            rowSpans: rowSpans
        )
    }

    @Test func fullFrameReplacesGrid() throws {
        var grid = HiveTerminalGridModel()
        grid.apply(try fullFrame())
        #expect(grid.hasContent)
        #expect(grid.columns == 10)
        #expect(grid.rows == 4)
        #expect(grid.plainRow(0) == "hello")
        #expect(grid.plainRow(1) == "  world")
        #expect(grid.plainRow(2) == "")
        #expect(grid.cursor?.row == 1)
        #expect(grid.cursor?.column == 7)
        #expect(grid.rowSpans[1].first?.style.bold == true)
        #expect(grid.terminalBackground == "#000000")
        #expect(grid.stateSeq == 1)
    }

    @Test func deltaClearsAndRepaintsOnlyItsRows() throws {
        var grid = HiveTerminalGridModel()
        grid.apply(try fullFrame())
        grid.apply(try deltaFrame(
            clearedRows: [0],
            rowSpans: [.init(row: 2, column: 0, styleID: 0, text: "third")]
        ))

        // Row 0 cleared, row 1 untouched, row 2 repainted.
        #expect(grid.plainRow(0) == "")
        #expect(grid.plainRow(1) == "  world")
        #expect(grid.plainRow(2) == "third")
        // A delta without a cursor leaves the previous cursor alone.
        #expect(grid.cursor?.row == 1)
        #expect(grid.stateSeq == 2)
    }

    @Test func deltaRepaintedRowReplacesPreviousSpans() throws {
        var grid = HiveTerminalGridModel()
        grid.apply(try fullFrame())
        grid.apply(try deltaFrame(
            stateSeq: 3,
            rowSpans: [.init(row: 1, column: 0, styleID: 0, text: "new")]
        ))
        // The row's old "  world" spans are gone, not merged.
        #expect(grid.plainRow(1) == "new")
    }

    @Test func deltaBeforeAnyFullFrameIsIgnored() throws {
        var grid = HiveTerminalGridModel()
        grid.apply(try deltaFrame(
            stateSeq: 5,
            rowSpans: [.init(row: 0, column: 0, styleID: 0, text: "orphan")]
        ))
        #expect(!grid.hasContent)
        #expect(grid.rows == 0)
    }

    @Test func deltaWithNewGeometryResizesGrid() throws {
        var grid = HiveTerminalGridModel()
        grid.apply(try fullFrame(columns: 10, rows: 4))
        grid.apply(try deltaFrame(
            columns: 12,
            rows: 6,
            stateSeq: 6,
            rowSpans: [.init(row: 5, column: 0, styleID: 0, text: "tail")]
        ))
        #expect(grid.columns == 12)
        #expect(grid.rows == 6)
        #expect(grid.plainRow(5) == "tail")
        // Existing rows survive the grow.
        #expect(grid.plainRow(0) == "hello")
    }

    @Test func wideGlyphSpansAdvanceByTotalCellWidth() throws {
        var grid = HiveTerminalGridModel()
        // The wire `cell_width` is the span's TOTAL width in cells: two wide
        // glyphs occupy columns 0-3.
        grid.apply(try fullFrame(rowSpans: [
            .init(row: 0, column: 0, styleID: 0, text: "日本", cellWidth: 4),
            .init(row: 0, column: 4, styleID: 0, text: "!"),
        ]))
        // The wide span occupies columns 0-3; no gap spaces before "!".
        #expect(grid.plainRow(0) == "日本!")
        #expect(grid.rowSpans[0].first?.totalCellWidth == 4)
        #expect(grid.rowSpans[0].first?.isUniformSingleWidth == false)
    }

    @Test func omittedCellWidthEstimatesFromText() throws {
        var grid = HiveTerminalGridModel()
        // No wire cell_width: the span width is estimated from the text (wide
        // glyphs count 2), so the following span still needs no gap fill.
        grid.apply(try fullFrame(rowSpans: [
            .init(row: 0, column: 0, styleID: 0, text: "日本"),
            .init(row: 0, column: 4, styleID: 0, text: "ok"),
        ]))
        #expect(grid.plainRow(0) == "日本ok")
        #expect(grid.rowSpans[0].first?.totalCellWidth == 4)
        // Plain ASCII spans stay single-width and drawable as one run.
        #expect(grid.rowSpans[0].last?.isUniformSingleWidth == true)
    }

    @Test func hostPaddedSpanAdvancesByWireWidth() throws {
        var grid = HiveTerminalGridModel()
        // The host may send cell_width wider than the text (padded run); the
        // next column must respect the wire width, with gap fill in between.
        grid.apply(try fullFrame(rowSpans: [
            .init(row: 0, column: 0, styleID: 0, text: "ab", cellWidth: 6),
            .init(row: 0, column: 8, styleID: 0, text: "cd"),
        ]))
        // Column after span 1 = 0 + 6; gap to column 8 = 2 spaces.
        #expect(grid.plainRow(0) == "ab  cd")
        #expect(grid.rowSpans[0].first?.totalCellWidth == 6)
    }
}
