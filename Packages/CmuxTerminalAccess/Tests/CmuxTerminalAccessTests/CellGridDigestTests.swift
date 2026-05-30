import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct CellGridDigestTests {
    private func grid(text: [String], cursor: CursorState) -> CellGrid {
        let rows = text.map { line -> CellRow in
            let cells = line.map { ch -> Cell in
                Cell(t: String(ch), wide: .narrow,
                     fg: .default, bg: .default,
                     attrs: [], underlineKind: nil, underlineColor: nil,
                     hyperlink: nil, semantic: nil)
            }
            return CellRow(wrap: false, wrapContinuation: false, cells: cells)
        }
        return CellGrid(cols: text.first?.count ?? 0, rows: text.count,
                        altScreen: false, title: nil,
                        cursor: cursor, semanticAvailable: false,
                        rowsData: rows)
    }

    @Test func equalGridsHashEqual() {
        let c = CursorState(row: 0, col: 0, visible: true, style: .block)
        #expect(CellGridDigest.compute(grid(text: ["abc"], cursor: c))
             == CellGridDigest.compute(grid(text: ["abc"], cursor: c)))
    }

    @Test func differentTextDigestsDiffer() {
        let c = CursorState(row: 0, col: 0, visible: true, style: .block)
        #expect(CellGridDigest.compute(grid(text: ["abc"], cursor: c))
             != CellGridDigest.compute(grid(text: ["abd"], cursor: c)))
    }

    @Test func differentCursorDigestsDiffer() {
        let a = CursorState(row: 0, col: 1, visible: true, style: .block)
        let b = CursorState(row: 0, col: 2, visible: true, style: .block)
        #expect(CellGridDigest.compute(grid(text: ["abc"], cursor: a))
             != CellGridDigest.compute(grid(text: ["abc"], cursor: b)))
    }

    @Test func nonZeroForNonEmptyGrid() {
        let c = CursorState(row: 0, col: 0, visible: true, style: .block)
        #expect(CellGridDigest.compute(grid(text: ["x"], cursor: c)) != 0)
    }

    @Test func differentWrapFlagsDiffer() {
        let c = CursorState(row: 0, col: 0, visible: true, style: .block)
        let g = grid(text: ["abc"], cursor: c)
        var rows = g.rowsData
        let r0 = rows[0]
        rows[0] = CellRow(wrap: true, wrapContinuation: r0.wrapContinuation, cells: r0.cells)
        let g2 = CellGrid(cols: g.cols, rows: g.rows, altScreen: g.altScreen,
                          title: g.title, cursor: g.cursor,
                          semanticAvailable: g.semanticAvailable, rowsData: rows)
        #expect(CellGridDigest.compute(g) != CellGridDigest.compute(g2))
    }
}
