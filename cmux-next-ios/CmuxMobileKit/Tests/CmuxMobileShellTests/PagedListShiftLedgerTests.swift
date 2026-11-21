import CoreGraphics
import Testing
@testable import CmuxMobileDesign

/// The frame-shift measure's account (verify/paged-list.md, "Frame shift"). Fleet steps
/// 506b47639ef1, 5b62e90dbe89, 7c392c159b35 and 3a7933b8d828 each failed on one frame: a cell above
/// the reader sized itself outside a layout pass (UIKit prepares cells ahead of the scroll), UIKit
/// moved the offset by the same amount to keep the reader still (the row did not move on screen),
/// and the measure took that move for the person's drag: `trail=m+86.3,d-20.0 moved=0.0
/// explained=-20.0`, a 20 pt shift no one saw.
struct PagedListShiftLedgerTests {
    /// The probe's shift for an interval: how far the row moved on screen plus what the scroll explains.
    private func shift(_ ledger: PagedListShiftLedger, moved: CGFloat) -> CGFloat { moved + ledger.explained }

    @Test func uikitsCorrectionForARowAboveTheReaderIsNotTheScroll() {
        var ledger = PagedListShiftLedger()
        // Row 12, above the reader, sized 20 pt shorter than the layout had it.
        ledger.sized(item: 12, by: -20, aboveReader: true)
        // UIKit's own offset set, outside a layout pass, while the person drags: it pays that.
        let paid = ledger.pays(-20)
        if !paid { ledger.explain(-20) }
        #expect(paid)
        // The row being read stayed where it was on screen: nothing shifted.
        #expect(shift(ledger, moved: 0) == 0)
    }

    @Test func aRowBelowTheReaderTopOwesNoCorrection() {
        var ledger = PagedListShiftLedger()
        // A row that starts below the reader's top grows: the rows below it move, the reader's does not.
        ledger.sized(item: 30, by: 20, aboveReader: false)
        let paid = ledger.pays(20)
        #expect(!paid)
        #expect(ledger.pending == 0)
    }

    @Test func aSizingTheLayoutAlsoCorrectsIsOwedOnce() {
        var ledger = PagedListShiftLedger()
        // The same row's size reaches the layout too (`invalidationContext(forPreferredLayoutAttributes:)`),
        // which asks for the same correction: one move pays it, a second is the person's.
        ledger.sized(item: 12, by: 20, aboveReader: true)
        ledger.corrected(20, item: 12)
        let first = ledger.pays(20)
        let second = ledger.pays(20)
        #expect(first)
        #expect(!second)
    }

    @Test func theFingersStepStillCounts() {
        var ledger = PagedListShiftLedger()
        // A drag with no sizing in between explains its move: a row that moved with it did not shift.
        let paid = ledger.pays(8)
        #expect(!paid)
        ledger.explain(8)
        #expect(shift(ledger, moved: -8) == 0)
    }

    /// Step ecc34bbc8080: a row above the reader sized 118 pt taller outside a layout pass, UIKit
    /// moved the offset 118 pt at once, and the next pass held the reader against its cell's frame
    /// from before that move, so it corrected the same 118 pt again: the reader jumped 118 pt
    /// (`trail=m+118.0,p+118.0,c+118.0 moved=-118.0`).
    @Test func aPassAfterUIKitsCorrectionHoldsTheReaderOnce() {
        var ledger = PagedListShiftLedger()
        ledger.sized(item: 4, by: 118, aboveReader: true)
        let paid = ledger.pays(118)
        #expect(paid)
        // The cells were laid out against offset 1000; UIKit's correction made it 1118.
        let held = ledger.takeDrawnOffset(1118)
        #expect(held == 1000)
        // That pass lays them out against 1118: the next one holds against the offset as it is.
        let next = ledger.takeDrawnOffset(1118)
        #expect(next == 1118)
        // A sample in between does not forget a correction no pass has laid out yet.
        ledger.sized(item: 5, by: 20, aboveReader: true)
        let again = ledger.pays(20)
        #expect(again)
        ledger.reset()
        let afterSample = ledger.takeDrawnOffset(1138)
        #expect(afterSample == 1118)
    }

    @Test func aSampleStartsTheNextIntervalEmpty() {
        var ledger = PagedListShiftLedger()
        ledger.sized(item: 3, by: 20, aboveReader: true)
        ledger.explain(5)
        ledger.reset()
        #expect(ledger.explained == 0)
        #expect(ledger.pending == 0)
    }

    /// A row that changes height in place moves one edge: no shift, whichever edge it is
    /// (up-*-flood kept the bottom, step 6d8bcee4; down-*-edits kept the top, step d20b5519).
    @Test func aRowChangingHeightInPlaceDrawsNoShift() {
        #expect(PagedListShiftLedger.drawnShift(top: -22, bottom: 0) == 0)
        #expect(PagedListShiftLedger.drawnShift(top: 0, bottom: -22) == 0)
        #expect(PagedListShiftLedger.drawnShift(top: -11, bottom: 11) == 0)
    }

    /// A move of the whole row counts in full, and a move that comes with a size change counts the
    /// part both edges share (the move), not the size change.
    @Test func aMoveOfTheWholeRowCountsWhatBothEdgesShare() {
        #expect(PagedListShiftLedger.drawnShift(top: 10, bottom: 10) == 10)
        #expect(PagedListShiftLedger.drawnShift(top: -10, bottom: -10) == -10)
        #expect(PagedListShiftLedger.drawnShift(top: 10, bottom: 32) == 10)
        #expect(PagedListShiftLedger.drawnShift(top: -410, bottom: -414.7) == -410)
    }

    /// The rule's limit, by choice: a jump in the same frame as a resize of the row being read.
    /// A resize the same way as the jump leaves the jump in full; a resize the other way hides as much
    /// of the jump as the resize's size, down to nothing (a 10 pt jump down while the row shrinks
    /// 22 pt at its bottom reports 0; with a 5 pt shrink it reports 5). A one-frame jump still counts
    /// on its way back, which comes with no resize; a jump that stays, landing in the very frame the
    /// row being read resizes the other way, is not seen.
    @Test func aJumpWithAnOppositeResizeOfTheRowBeingReadCountsLessByTheResize() {
        #expect(PagedListShiftLedger.drawnShift(top: 10, bottom: 10 + 22) == 10)
        #expect(PagedListShiftLedger.drawnShift(top: 10, bottom: 10 - 5) == 5)
        #expect(PagedListShiftLedger.drawnShift(top: 10, bottom: 10 - 22) == 0)
        #expect(PagedListShiftLedger.drawnShift(top: -10 + 22, bottom: -10) == 0)
    }
}
