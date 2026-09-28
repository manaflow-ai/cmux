import GhosttyKit
import Testing
@testable import CmuxTerminal

@Suite
struct TerminalTextRegionTests {
    /// A 50-row, 80-column viewport whose content fills rows 0 through 19;
    /// row 19 is an agent footer, rows 20 through 49 are blank.
    private let shortViewport: [String] = (0..<50).map { row in
        switch row {
        case 0..<19: "output line \(row)"
        case 19: "  ⏵⏵ accept edits on (shift+tab to cycle)"
        default: ""
        }
    }

    @Test(arguments: [0, 19, 35, 49])
    func aViewportRowSelectsExactlyThatRow(row: Int) {
        let selection = TerminalTextRegion.viewportRow(row, columns: 80).selection
        #expect(selection.top_left.tag == GHOSTTY_POINT_VIEWPORT)
        #expect(selection.top_left.coord == GHOSTTY_POINT_COORD_EXACT)
        #expect(selection.top_left.x == 0)
        #expect(selection.top_left.y == UInt32(row))
        #expect(selection.bottom_right.tag == GHOSTTY_POINT_VIEWPORT)
        #expect(selection.bottom_right.coord == GHOSTTY_POINT_COORD_EXACT)
        #expect(selection.bottom_right.x == 79)
        #expect(selection.bottom_right.y == UInt32(row))
        #expect(!selection.rectangle)
    }

    @Test func aBlankRowBelowShortContentReadsBlank() {
        // Reading by row, not by bottom-aligning the trimmed viewport text,
        // keeps row 35 blank and row 19 on the footer.
        #expect(read(.viewportRow(35, columns: 80), from: shortViewport) == "")
        #expect(read(.viewportRow(19, columns: 80), from: shortViewport) == shortViewport[19])
    }

    @Test func aSoftWrappedLineIsReadOneRowAtATime() {
        // One logical line wrapped at 20 columns over rows 3 and 4.
        var viewport = Array(repeating: "", count: 10)
        viewport[3] = "  ⎿  … +53 lines (ct"
        viewport[4] = "rl+o to expand)"
        #expect(read(.viewportRow(4, columns: 20), from: viewport) == "rl+o to expand)")
        #expect(read(.viewportRow(3, columns: 20), from: viewport) == "  ⎿  … +53 lines (ct")
    }

    @Test func wholeRegionsKeepTheirCorners() {
        let viewport = TerminalTextRegion.viewport.selection
        #expect(viewport.top_left.coord == GHOSTTY_POINT_COORD_TOP_LEFT)
        #expect(viewport.bottom_right.coord == GHOSTTY_POINT_COORD_BOTTOM_RIGHT)
        #expect(TerminalTextRegion.history.selection.top_left.tag == GHOSTTY_POINT_SURFACE)
    }

    /// Applies an exact viewport selection to a grid of rows the way Ghostty
    /// reads cells: rows top through bottom, each row's cells from the
    /// selection's columns, with no joining across soft wraps.
    private func read(_ region: TerminalTextRegion, from rows: [String]) -> String? {
        let selection = region.selection
        guard selection.top_left.tag == GHOSTTY_POINT_VIEWPORT,
              selection.top_left.coord == GHOSTTY_POINT_COORD_EXACT,
              selection.bottom_right.coord == GHOSTTY_POINT_COORD_EXACT,
              Int(selection.bottom_right.y) < rows.count else { return nil }
        return (Int(selection.top_left.y)...Int(selection.bottom_right.y)).map { row in
            String(rows[row].prefix(Int(selection.bottom_right.x) + 1).dropFirst(Int(selection.top_left.x)))
        }.joined(separator: "\n")
    }
}
