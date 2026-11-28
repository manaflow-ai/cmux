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

    /// Edits only (the stress bench's `edits` load: rows change height, none comes, goes or moves):
    /// every anchored row keeps its index, so the read row is kept, as restore's earlier rule did.
    /// The anchor pick cannot change what an edits-only update keeps still (up-fast-edits 74.1 pt at
    /// 873a9917, step 843cd21e, is a row above sizing after the restore: `r'+2056, c+2056, ..., m+74`).
    @Test func editsOnlyKeepTheReadRow() {
        #expect(PagedListAnchorPick.pick(rows([(63, 63), (64, 64), (65, 65), (66, 66), (67, 67)])) == 0)
        #expect(PagedListAnchorPick.pick(rows([(100, 100), (99, 99), (98, 98)])) == 0)
    }

    /// A row grew above the anchored rows (an edits-only update: no index moved): every row is in
    /// place, so the first is kept, the row being read. How far each moved on screen is not a reason
    /// to pass over it: a row under a grown row, an insert or a removal moves by design. Keeping the
    /// in-place row that moved least instead (23f9d387, with its guard) moved the row being read by
    /// 40-444 pt under inserts, the flood and a resting finger (0b7d601b, 26 of 30 stress cases red),
    /// so the pick reads indices only.
    @Test func anEditsOnlyUpdateKeepsTheFirstRow() {
        #expect(PagedListAnchorPick.pick(rows([(20, 20), (21, 21), (22, 22)])) == 0)
    }

    /// An insert far above and a removal right under the row being read: every survivor's index moved,
    /// all are in place, and the row being read is kept (the least-moved rule kept the row under the
    /// removed one: 0b7d601b down-fast-flood `U-74.3 ... r'+86.3`).
    @Test func anInsertAboveAndARemovalUnderTheReadRowKeepTheReadRow() {
        #expect(PagedListAnchorPick.pick(rows([(10, 11), (12, 12), (13, 13)])) == 0)
    }

    // MARK: The order the restore tries the rows in

    /// The row being read (the last pass's) first, then the rows after it, then those before it,
    /// nearest first.
    @Test func theRowBeingReadIsTriedFirstThenTheRowsAfterItThenThoseBefore() {
        #expect(PagedListAnchorPick.candidates(count: 5, reading: 2, straddles: true) == [2, 3, 4, 1, 0])
        #expect(PagedListAnchorPick.candidates(count: 4, reading: 0, straddles: false) == [0, 1, 2, 3])
    }

    /// The row being read carried past the top edge before the update (a fling's step): it is still
    /// the first one tried, though it is cut by the edge (bd734f10, 0b7d601b: one-row shifts of
    /// 126-146 pt when the row under it was kept instead).
    @Test func theRowBeingReadCutByTheTopEdgeIsStillTriedFirst() {
        #expect(PagedListAnchorPick.candidates(count: 3, reading: 0, straddles: true) == [0, 1, 2])
    }

    /// No row being read among them (none had its top in view at the last pass, or it left the
    /// anchor): every row in order, less a first row cut by the top edge (d20b5519: a cut row that
    /// changes height keeps the rows below it still).
    @Test func withoutTheRowBeingReadACutFirstRowIsSkipped() {
        #expect(PagedListAnchorPick.candidates(count: 3, reading: nil, straddles: true) == [1, 2])
        #expect(PagedListAnchorPick.candidates(count: 3, reading: nil, straddles: false) == [0, 1, 2])
        // A cut row alone on screen keeps its own top.
        #expect(PagedListAnchorPick.candidates(count: 1, reading: nil, straddles: true) == [0])
        #expect(PagedListAnchorPick.candidates(count: 0, reading: nil, straddles: false).isEmpty)
        // A stale position is ignored.
        #expect(PagedListAnchorPick.candidates(count: 2, reading: 5, straddles: false) == [0, 1])
    }

    /// One row left: it is kept.
    @Test func aLoneRowIsKept() {
        #expect(PagedListAnchorPick.pick(rows([(10, 12)])) == 0)
    }
}
#endif
