import CmuxTerminalRenderCore
import Testing

@Suite struct TerminalCellGeometryTests {
    let geometry = TerminalCellGeometry(cols: 80, rows: 24, cellWidth: 7.5, cellHeight: 15, paddingLeft: 4, paddingTop: 2)

    @Test func pointToCell() {
        #expect(geometry.cell(atX: 4, y: 2) == .init(column: 0, row: 0))
        #expect(geometry.cell(atX: 80, y: 61) == .init(column: 10, row: 3))
        #expect(geometry.cell(atX: 603.99, y: 361.99) == .init(column: 79, row: 23))
    }

    @Test func paddingAndOutsideAreNotCells() {
        #expect(geometry.cell(atX: 3.9, y: 10) == nil)
        #expect(geometry.cell(atX: 604, y: 10) == nil)
        #expect(geometry.cell(atX: 10, y: 362) == nil)
    }

    @Test func clampedCellStaysInside() {
        #expect(geometry.clampedCell(atX: -100, y: -100) == .init(column: 0, row: 0))
        #expect(geometry.clampedCell(atX: 10_000, y: 10_000) == .init(column: 79, row: 23))
    }

    @Test func frameAndCenterRoundTrip() {
        let cell = TerminalCellGeometry.Cell(column: 12, row: 7)
        let frame = geometry.frame(of: cell, widthCells: 2)
        #expect(frame.x == 94)
        #expect(frame.y == 107)
        #expect(frame.width == 15)
        #expect(frame.height == 15)
        let center = geometry.center(of: cell)
        #expect(geometry.cell(atX: center.x, y: center.y) == cell)
    }

    @Test func invalidGeometryHasNoCells() {
        #expect(TerminalCellGeometry(cols: 0, rows: 24, cellWidth: 7, cellHeight: 14).cell(atX: 1, y: 1) == nil)
        #expect(TerminalCellGeometry(cols: 80, rows: 24, cellWidth: 0, cellHeight: 14).clampedCell(atX: 1, y: 1) == nil)
    }
}
