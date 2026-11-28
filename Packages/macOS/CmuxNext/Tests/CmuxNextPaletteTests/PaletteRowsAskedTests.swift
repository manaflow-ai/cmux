import AppKit
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// New results of the same shape ask the table for no cell (``PaletteRowsKeptTests``): the rows on screen are
/// configured again, and only rows that were not on screen before are made.
@MainActor
@Suite(.closesItsWindows)
struct PaletteRowsAskedTests {
    @Test func resultsOfTheSameShapeAskForNoCell() throws {
        let (list, table, window) = try PaletteRowsKeptTests.host()
        defer { window.closeAfterTest() }
        list.setSections(PaletteRowsKeptTests.sections("a", [3, 4]))
        PaletteRowsKeptTests.settle(list)
        let first = list.cellsAsked
        #expect(first >= table.numberOfRows, "the first results asked for \(first) cells for \(table.numberOfRows) rows")

        for prefix in ["b", "c", "a"] {
            list.setSections(PaletteRowsKeptTests.sections(prefix, [3, 4]))
            PaletteRowsKeptTests.settle(list)
        }
        #expect(list.cellsAsked == first, "three updates of the same shape asked for \(list.cellsAsked - first) cells")
    }

    @Test func moreRowsAskOnlyForTheNewRows() throws {
        let (list, table, window) = try PaletteRowsKeptTests.host()
        defer { window.closeAfterTest() }
        list.setSections(PaletteRowsKeptTests.sections("a", [3, 2]))
        PaletteRowsKeptTests.settle(list)
        let first = list.cellsAsked
        list.setSections(PaletteRowsKeptTests.sections("b", [3, 5]))
        PaletteRowsKeptTests.settle(list)
        #expect(table.numberOfRows == 10)
        #expect(list.cellsAsked - first == 3, "3 rows came; the update asked for \(list.cellsAsked - first) cells")
        list.setSections(PaletteRowsKeptTests.sections("c", [3, 1]))
        PaletteRowsKeptTests.settle(list)
        #expect(table.numberOfRows == 6)
        #expect(list.cellsAsked - first == 3, "fewer rows asked for cells")
    }

    @Test func anotherShapeAsksForEveryRow() throws {
        let (list, table, window) = try PaletteRowsKeptTests.host()
        defer { window.closeAfterTest() }
        list.setSections(PaletteRowsKeptTests.sections("a", [3, 4]))
        PaletteRowsKeptTests.settle(list)
        let first = list.cellsAsked
        list.setSections(PaletteRowsKeptTests.sections("b", [1, 6]))
        PaletteRowsKeptTests.settle(list)
        #expect(list.cellsAsked - first >= table.numberOfRows, "another shape kept a row of another kind")
    }
}
