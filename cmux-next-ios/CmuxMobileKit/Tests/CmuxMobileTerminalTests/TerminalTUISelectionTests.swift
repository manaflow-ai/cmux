import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// G-14 in a full-screen app (vim, htop): a long press always selects, like
/// Shift-drag in Ghostty when the app captures the mouse. The alternate screen
/// has no scrollback, so a cell is a viewport row (0 = the top row) and a column.
@Suite struct TerminalTUISelectionTests {
    typealias P = TerminalCellPoint
    let geometry = TerminalTUISelectionGeometry(cellSize: CGSize(width: 8, height: 16),
                                                padding: CGPoint(x: 2, y: 4), rows: 40, columns: 50)

    @Test func aPointMapsToTheViewportCellUnderIt() {
        #expect(geometry.cell(at: CGPoint(x: 2, y: 4)) == P(row: 0, column: 0))
        #expect(geometry.cell(at: CGPoint(x: 2 + 8 * 7 + 3, y: 4 + 16 * 12 + 15)) == P(row: 12, column: 7))
    }

    @Test func pointsOffTheGridClampToItsEdges() {
        #expect(geometry.cell(at: CGPoint(x: -30, y: -50)) == P(row: 0, column: 0))
        #expect(geometry.cell(at: CGPoint(x: 9_000, y: 9_000)) == P(row: 39, column: 49))
    }

    @Test func aCellsRectIsTheInverseOfTheMapping() {
        let rect = geometry.rect(for: P(row: 12, column: 7))
        #expect(rect == CGRect(x: 2 + 56, y: 4 + 192, width: 8, height: 16))
        #expect(geometry.cell(at: CGPoint(x: rect.midX, y: rect.midY)) == P(row: 12, column: 7))
    }

    @Test func anEmptyGridHasNoCell() {
        let empty = TerminalTUISelectionGeometry(cellSize: .zero, padding: .zero, rows: 0, columns: 0)
        #expect(empty.cell(at: CGPoint(x: 10, y: 10)) == nil)
    }

    @Test func selectAllCoversTheWholeScreen() {
        let all = geometry.all
        #expect(all.start == P(row: 0, column: 0))
        #expect(all.end == P(row: 39, column: 49))
    }
}
