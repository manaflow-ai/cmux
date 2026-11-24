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

    /// Defect (2), during a fling under mid-list inserts: the reader is cut by the top edge (dropped),
    /// two anchored rows survive. One kept its place on screen (moved 0 pt with the rest); the other was
    /// moved by the load and travelled 416 pt. Both keep their order, so the run cannot tell them apart;
    /// the row that stayed is the one to keep (full 27 208073e6 up-fast-inserts `U-208, r'+416`).
    @Test func ofTwoInPlaceRowsTheOneThatDidNotTravelIsKept() {
        let rows = [Row(oldIndex: 11, newIndex: 14, moved: 416), Row(oldIndex: 12, newIndex: 15, moved: 0)]
        #expect(PagedListAnchorPick.pick(rows) == 1)
    }

    /// The same with the reader in the anchor: rows inserted just above it, and the next anchored row
    /// moved far. The reader moved least: kept (today's rule keeps it too; this guards the fix).
    @Test func theReaderWhichMovedLeastIsKeptUnderInserts() {
        let rows = [Row(oldIndex: 20, newIndex: 23, moved: 0.3), Row(oldIndex: 21, newIndex: 24, moved: 445)]
        #expect(PagedListAnchorPick.pick(rows) == 0)
    }

    /// One row left: it is kept.
    @Test func aLoneRowIsKept() {
        #expect(PagedListAnchorPick.pick(rows([(10, 12)])) == 0)
    }
}
#endif
