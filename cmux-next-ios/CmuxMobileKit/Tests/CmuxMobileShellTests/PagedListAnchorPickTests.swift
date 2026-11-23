#if os(iOS)
import Testing
@testable import CmuxMobileDesign

/// The row the list keeps still after an update (``PagedListAnchorPick``), as plain data: each
/// anchored row's index before and after, the row being read first.
struct PagedListAnchorPickTests {
    typealias Row = PagedListAnchorPick.Row

    private func rows(_ pairs: [(Int, Int)]) -> [Row] { pairs.map { Row(oldIndex: $0.0, newIndex: $0.1) } }

    /// Rows inserted right under the row being read (the stress bench's mid-list inserts): the read
    /// row kept its place, so it is the one kept still. Picking the next row instead let the inserted
    /// rows push the read row up by their height (stack3 baseline 05921b74: down-medium-inserts
    /// `U-14.3, r'-60`, down-fast-busy `r'+192.7`, up-medium-inserts `r'+104`, 106-170 pt).
    @Test func rowsInsertedUnderTheReadRowKeepTheReadRowStill() {
        #expect(PagedListAnchorPick.pick(rows([(10, 10), (11, 14), (12, 15), (13, 16)])) == 0)
    }

    /// The same at an `.up` list's newest end: the anchor reads bottoms, lowest first, and rows
    /// arrive between the lowest and the one above it.
    @Test func rowsInsertedAboveTheLowestRowKeepTheLowestRowStill() {
        #expect(PagedListAnchorPick.pick(rows([(100, 104), (99, 99), (98, 98)])) == 0)
    }

    /// Rows inserted above all of them move every index alike: the read row.
    @Test func rowsInsertedAboveTheAnchorKeepTheReadRowStill() {
        #expect(PagedListAnchorPick.pick(rows([(10, 15), (11, 16), (12, 17)])) == 0)
    }

    /// The read row went to the newest end (moveToNewest): it is not followed, the next row is.
    @Test func aReadRowMovedElsewhereIsNotKept() {
        #expect(PagedListAnchorPick.pick(rows([(10, 500), (11, 10), (12, 11), (13, 12)])) == 1)
    }

    /// The read row moved a few rows down among the others: not followed either.
    @Test func aReadRowMovedAmongTheOthersIsNotKept() {
        #expect(PagedListAnchorPick.pick(rows([(10, 13), (11, 10), (12, 11), (13, 12)])) == 1)
    }

    /// Two rows and the read row went far: of two runs of one row each, the read row is not the one
    /// followed (it could have moved).
    @Test func ofTwoRowsTheReadRowMovedFarIsNotKept() {
        #expect(PagedListAnchorPick.pick(rows([(10, 500), (11, 10)])) == 1)
    }

    /// One row left: it is kept.
    @Test func aLoneRowIsKept() {
        #expect(PagedListAnchorPick.pick(rows([(10, 12)])) == 0)
    }
}
#endif
