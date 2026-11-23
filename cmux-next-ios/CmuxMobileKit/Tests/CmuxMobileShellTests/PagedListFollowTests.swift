#if os(iOS)
import CoreGraphics
import Testing
@testable import CmuxMobileDesign

/// The row the frame-shift measures follow between two committed frames (``PagedListFollow``), as
/// plain data: what the list drew in each frame, row by row.
struct PagedListFollowTests {
    typealias Row = PagedListFollow.Row<Int>

    /// Rows 10...16 drawn 60 pt apart from `top`, in screen order.
    private func screen(_ ids: [Int], top: CGFloat = 100) -> [Row] {
        ids.enumerated().map { Row(id: $0.element, y: top + CGFloat($0.offset) * 60) }
    }

    private func shift(_ previous: [Row], _ current: [Row], reading: Int) -> CGFloat? {
        PagedListFollow.pick(previous: previous, current: current, reading: reading).map { $0.now - $0.was }
    }

    /// The row being read moves to the far end of the list (the load's moveToNewest) and the anchor
    /// keeps the next row where the reader saw it: nothing the reader sees moved. Following the
    /// moved row by its id read its whole trip (stress inserts at 883cf351: 19,145 pt with the drawn
    /// measure at 598, step 18f2cbb5).
    @Test func theReadRowMovingElsewhereInTheListIsNotAShift() throws {
        let before = screen([10, 11, 12, 13, 14, 15])
        // Row 10 went to the newest end, 19,000 pt away; rows 11 on stay where they were drawn.
        var after = screen([11, 12, 13, 14, 15, 16], top: 160)
        after.append(Row(id: 10, y: 19_100))
        let moved = try #require(shift(before, after, reading: 10))
        #expect(abs(moved) <= 0.5, "a row that moved elsewhere in the list read as a \(moved) pt shift")
    }

    /// The same, with the moved row still on screen (it went a few rows down).
    @Test func theReadRowMovingAmongTheRowsOnScreenIsNotAShift() throws {
        let before = screen([10, 11, 12, 13, 14, 15])
        // Rows 11-13 stay; row 10 now sits between 13 and 14, which moved down a row for it.
        let after = screen([11, 12, 13, 10, 14, 15], top: 160)
        let moved = try #require(shift(before, after, reading: 10))
        #expect(abs(moved) <= 0.5, "a row that moved among the rows on screen read as a \(moved) pt shift")
    }

    /// Everything drawn 10 pt lower in the frame a row arrives right after the row being read: the
    /// arrival does not excuse the move (c7a938de's case: the up-slow-flood frame that drew the
    /// rows 75 pt off while a row went next to the reader).
    @Test func aDrawnJumpInTheFrameARowArrivesNextToTheReaderCountsInFull() throws {
        let before = screen([10, 11, 12, 13, 14, 15])
        let after = screen([10, 99, 11, 12, 13, 14], top: 110)
        let moved = try #require(shift(before, after, reading: 10))
        #expect(abs(moved - 10) < 0.5, "a 10 pt jump with a row arriving next to the reader read \(moved) pt")
    }

    /// The same jump in the frame the row next to the reader goes.
    @Test func aDrawnJumpInTheFrameARowNextToTheReaderGoesCountsInFull() throws {
        let before = screen([10, 11, 12, 13, 14, 15])
        let after = screen([10, 12, 13, 14, 15, 16], top: 110)
        let moved = try #require(shift(before, after, reading: 10))
        #expect(abs(moved - 10) < 0.5, "a 10 pt jump with the row next to the reader gone read \(moved) pt")
    }

    /// Nothing changed: no shift.
    @Test func aStillFrameIsNoShift() throws {
        let rows = screen([10, 11, 12, 13])
        let moved = try #require(shift(rows, rows, reading: 10))
        #expect(abs(moved) <= 0.5)
    }
}
#endif
