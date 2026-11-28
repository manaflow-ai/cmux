#if os(iOS)
import CoreGraphics
import Testing
@testable import CmuxMobileDesign

/// The neighbour measure (``PagedListFollow/neighbourShift(previous:current:reading:explained:around:)``),
/// a check that shares no rule with the row the anchor keeps still or the measures follow: the rows
/// around the eye line, each judged only when nothing between it and the read row changed.
struct PagedListNeighbourTests {
    typealias Row = PagedListFollow.Drawn<Int>

    private func screen(_ ids: [Int], top: CGFloat = 100, heights: [Int: CGFloat] = [:]) -> [Row] {
        var y = top
        return ids.map { id in
            let h = heights[id] ?? 60
            defer { y += h }
            return Row(id: id, y: y, height: h)
        }
    }

    private func shift(_ previous: [Row], _ current: [Row], reading: Int = 12, explained: CGFloat = 0) -> CGFloat {
        PagedListFollow.neighbourShift(previous: previous, current: current, reading: reading, explained: explained)?.shift ?? 0
    }

    /// The read row stays and the two rows under it draw 10 pt lower with nothing between them
    /// changed: what the reader was looking at jumped, whichever row the anchor kept.
    @Test func rowsUnderTheReadRowJumpingCount() {
        let before = screen([10, 11, 12, 13, 14, 15])
        var after = before
        after[3].y += 10
        after[4].y += 10
        #expect(abs(shift(before, after) - 10) < 0.5)
    }

    /// A row inserted under the read row pushes the rows under it: by design, not counted.
    @Test func rowsPushedByAnArrivalBetweenDoNotCount() {
        let before = screen([10, 11, 12, 13, 14, 15])
        let after = screen([10, 11, 12, 99, 13, 14])
        #expect(abs(shift(before, after)) <= 0.5)
    }

    /// The read row grows: the rows under it move by the growth, by design.
    @Test func rowsPushedByTheReadRowGrowingDoNotCount() {
        let before = screen([10, 11, 12, 13, 14, 15])
        let after = screen([10, 11, 12, 13, 14, 15], heights: [12: 82])
        #expect(abs(shift(before, after)) <= 0.5)
    }

    /// A scroll moves everything; the scroll explains it.
    @Test func aScrollExplainedIsNoShift() {
        let before = screen([10, 11, 12, 13, 14, 15])
        let after = screen([10, 11, 12, 13, 14, 15], top: 70)
        #expect(abs(shift(before, after, explained: 30)) <= 0.5)
    }

    /// The whole screen jumps 20 pt with no scroll: the neighbours count it too.
    @Test func aWholeScreenJumpCounts() {
        let before = screen([10, 11, 12, 13, 14, 15])
        let after = screen([10, 11, 12, 13, 14, 15], top: 120)
        #expect(abs(shift(before, after) - 20) < 0.5)
    }

    /// The row above the read row jumps alone (the row just above, nothing between): it counts.
    @Test func theRowAboveJumpingCounts() {
        let before = screen([10, 11, 12, 13, 14, 15])
        var after = before
        after[1].y -= 10
        after[0].y -= 10
        #expect(abs(abs(shift(before, after)) - 10) < 0.5)
    }
}
#endif
