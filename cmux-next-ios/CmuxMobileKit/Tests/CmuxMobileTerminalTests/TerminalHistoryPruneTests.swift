import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// termqa round 6, VERIFY-round5 V2-3 (eviction) and V5-2.
///
/// At the scrollback cap Ghostty prunes its oldest rows a page at a time:
/// the total drops by hundreds of rows, and a viewport in the scrollback
/// keeps its rows, so its reported top drops by the same count. The phone
/// kept every absolute row it held (the reading anchor, the presented and
/// requested viewport tops, the scroll offset) in the old numbering. A
/// reset then read the mark at the old row number, about 900 rows lower in
/// the text (`reading mark restored row 15047 -> 15047 of 17493`), and a
/// fling over the shorter document ran into its end and followed (V5-2).
@Suite struct TerminalHistoryPruneTests {
    @Test func aPruneUnderAViewportInTheScrollbackIsCounted() {
        // 887 rows pruned, 20 new rows appended meanwhile.
        let rows = TerminalHistoryPrune.prunedRows(previousTotal: 17322, previousOffset: 15000,
                                                   total: 17322 - 887 + 20, offset: 15000 - 887,
                                                   requestedTop: 15000, rows: 150)
        #expect(rows == 887)
    }

    @Test func aRequestOrAClearIsNotAPrune() {
        // Our own request moved the viewport up: the total grew.
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17000, previousOffset: 15000, total: 17010, offset: 14900,
                                                requestedTop: 14900, rows: 150) == nil)
        // A request was still in flight (the old report was not the one asked for).
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17322, previousOffset: 15000, total: 16455, offset: 14113,
                                                requestedTop: 14200, rows: 150) == nil)
        // `clear` (ESC [3J): the scrollback is gone, nothing to keep.
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17322, previousOffset: 15000, total: 150, offset: 0,
                                                requestedTop: 15000, rows: 150) == nil)
        // The viewport fell by more than the history shrank plus nothing: not one count.
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17322, previousOffset: 15000, total: 17300, offset: 14000,
                                                requestedTop: 15000, rows: 150) == nil)
    }

    /// VERIFY-round8 claim 1b (T-FOLLOW-04): following at the cap, Ghostty
    /// pruned 886 rows (17739 -> 16853 + new rows) with its viewport on the
    /// active area before and after. No prune was counted, so the frame on
    /// screen kept its top in the old numbering while the document shrank
    /// under it: the page showed rows the frame did not cover, one black frame.
    /// The rows the frame on screen moves up by are the total's shrink.
    @Test func aPruneUnderTheFollowedBottomIsCounted() {
        let rows = 151
        // 886 rows pruned, 12 appended meanwhile; the request is stale (following).
        let total = 17739 - 886 + 12
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17739, previousOffset: 17739 - rows,
                                                total: total, offset: total - rows,
                                                requestedTop: 17500, rows: rows) == 874)
        // Following, output only: the total grew.
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17739, previousOffset: 17739 - rows,
                                                total: 17750, offset: 17750 - rows, requestedTop: 17500, rows: rows) == nil)
        // Following, `clear`: the history is gone, nothing to keep.
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17739, previousOffset: 17739 - rows,
                                                total: rows, offset: 0, requestedTop: 17500, rows: rows) == nil)
    }

    @Test func theReadingAnchorMovesWithThePrune() {
        var model = TerminalScrollModel()
        model.restoreReading(.init(row: 15047, delta: 3))
        model.shiftRows(by: -887)
        #expect(model.state == .reading(.init(row: 14160, delta: 3)))
        var following = TerminalScrollModel()
        following.shiftRows(by: -887)
        #expect(following.isFollowing)
    }

    /// V5-2: a fling up from the live bottom that rests a few rows above it
    /// reads; it is not "a fling into the bottom" (the gesture began there).
    @Test func anUpwardFlingFromTheBottomDoesNotFollow() {
        let cell: CGFloat = 16
        let layout = TerminalDocumentLayout(originRow: 0, endRow: 2000)
        let bottom: CGFloat = 1900 * cell
        var model = TerminalScrollModel()
        model.began()
        model.scrolled(offsetY: bottom, bottomOffsetY: bottom)
        model.scrolled(offsetY: bottom - 2 * cell, bottomOffsetY: bottom)
        model.scrolled(offsetY: bottom - 5 * cell, bottomOffsetY: bottom)
        model.settled(offsetY: bottom - 5 * cell, bottomOffsetY: bottom, layout: layout, rowHeight: cell)
        #expect(model.state == .reading(.init(row: 1895, delta: 0)))
    }

    /// A fling down into the bottom while output streams ends a few rows
    /// short of the newest end: it still follows (the touched-bottom slack).
    @Test func aDownwardFlingIntoTheBottomFollows() {
        let cell: CGFloat = 16
        let layout = TerminalDocumentLayout(originRow: 0, endRow: 2000)
        let bottom: CGFloat = 1900 * cell
        var model = TerminalScrollModel()
        model.restoreReading(.init(row: 1000, delta: 0))
        model.began()
        model.scrolled(offsetY: 1500 * cell, bottomOffsetY: bottom)
        model.scrolled(offsetY: bottom, bottomOffsetY: bottom)
        // The bounce back and the output that grew the end meanwhile.
        model.scrolled(offsetY: bottom + 4, bottomOffsetY: bottom + 6 * cell)
        model.settled(offsetY: bottom, bottomOffsetY: bottom + 6 * cell, layout: layout, rowHeight: cell)
        #expect(model.isFollowing)
    }
}

/// VERIFY-round5 V5-1 (Jump to bottom tap): the offset moved to the live end
/// at once, while the surface still showed the scrollback rows it had: the
/// page was black for a frame until Ghostty presented the end. A move whose
/// visible rows the presented frame does not cover now waits for the frame
/// that does (like following output).
@Suite struct TerminalFrameCoverTests {
    @Test func aJumpOutsideThePresentedRowsWaitsForItsFrame() {
        // Presented rows 1000..<1150; the end's visible rows 16950..<17000.
        #expect(!TerminalFrameCover(presentedTop: 1000, surfaceRows: 150).covers(visibleTop: 16950, visibleBottom: 17000))
        #expect(TerminalFrameCover(presentedTop: 16860, surfaceRows: 150).covers(visibleTop: 16950, visibleBottom: 17000))
        // One row short at the bottom: not covered.
        #expect(!TerminalFrameCover(presentedTop: 16849, surfaceRows: 150).covers(visibleTop: 16950, visibleBottom: 17000))
    }
}

extension TerminalFrameCoverTests {
    @Test func followingAStepIsNotAJump() {
        let cover = TerminalFrameCover(presentedTop: 16850, surfaceRows: 150)
        #expect(!cover.isDisjoint(visibleTop: 16955, visibleBottom: 17003))
        #expect(cover.isDisjoint(visibleTop: 17000, visibleBottom: 17050))
        #expect(TerminalFrameCover(presentedTop: 1000, surfaceRows: 150).isDisjoint(visibleTop: 16950, visibleBottom: 17000))
    }
}

/// VERIFY-round8 claim 1a (T-SCROLL-02/09): a one-frame full black on about
/// 40 % of Jump to bottom taps at the history cap. The jump waited for the
/// end's frame only when none of its rows were on screen, and only for six
/// display frames: under fast output Ghostty's frame for the end came later,
/// the fallback moved the page anyway, and the old frame (the reading rows)
/// left the end's rows black until the next present. A target only partly
/// in the frame moved at once with the rest black. The page now moves only
/// to rows the frame on screen covers, and keeps the last good frame until
/// the new one is placed (up to `maxWait`, inside T-SCROLL-09's 400 ms).
@Suite struct TerminalScrollGateTests {
    @Test func aTargetPartlyOutsideTheFrameWaits() {
        // The frame shows 16700..<16851; the end shows 16815..<16860.
        let cover = TerminalFrameCover(presentedTop: 16700, surfaceRows: 151)
        #expect(!cover.isDisjoint(visibleTop: 16815, visibleBottom: 16860))
        #expect(!TerminalScrollGate.movesNow(cover: cover, visibleTop: 16815, visibleBottom: 16860, documentRows: 0..<16860))
        #expect(TerminalScrollGate.movesNow(cover: TerminalFrameCover(presentedTop: 16709, surfaceRows: 151),
                                            visibleTop: 16815, visibleBottom: 16860, documentRows: 0..<16860))
        // Rows past the document's end are the page's own background.
        #expect(TerminalScrollGate.movesNow(cover: cover, visibleTop: 16815, visibleBottom: 16900, documentRows: 0..<16851))
    }

    @Test func theFallbackNeverMovesToUncoveredRowsBeforeTheMaximumWait() {
        // Six display frames at 120 Hz: the end's frame is not in yet.
        #expect(!TerminalScrollGate.fallbackMoves(covered: false, waited: 0.05))
        #expect(!TerminalScrollGate.fallbackMoves(covered: false, waited: 0.25))
        // qa11 wt-fling-c/d: never, not even past the maximum wait (3-frame blacks).
        #expect(!TerminalScrollGate.fallbackMoves(covered: false, waited: TerminalScrollGate.maxWait))
        #expect(!TerminalScrollGate.fallbackMoves(covered: false, waited: 5))
        #expect(TerminalScrollGate.fallbackMoves(covered: true, waited: 0.02))
        #expect(TerminalScrollGate.maxWait < 0.4)
    }
}

/// qa11 wt-fling-b (W-T at the cap, 2 of 60 jumps): reading rows, one fully
/// black frame (the scroll indicator still at the reading position), then
/// the live bottom. The jump waited for the end's frame; Ghostty's frame for
/// the end arrived and was placed at the end, replacing the reading frame,
/// but rows that arrived meanwhile left the end's last rows outside it, so
/// the page kept waiting at the reader's rows with nothing under them. The
/// frame on screen is the only frame there is: when it no longer covers the
/// page, the page goes to the rows it covers nearest the target, and the
/// rest of the move waits for the next frame.
@Suite struct TerminalScrollGateInterimTests {
    let viewport: CGFloat = 800

    @Test func aPlacedFrameThatLeavesThePageUncoveredMovesItToTheFramesRows() {
        // Content y: the end's frame covers 270000..<272400; the target
        // (the end) needs 271700..<272500; the page is at 266000.
        let y = TerminalScrollGate.interimOffset(frame: 270000..<272400, document: 0..<272500, current: 266000,
                                                 target: 271700, viewport: viewport)
        #expect(y == 272400 - viewport)
    }

    @Test func aPageTheFrameStillCoversKeepsWaiting() {
        // The frame on screen still shows the reader's rows.
        #expect(TerminalScrollGate.interimOffset(frame: 265500..<267900, document: 0..<272500, current: 266000,
                                                 target: 271700, viewport: viewport) == nil)
        // Rows past the document's end are the page's own background.
        #expect(TerminalScrollGate.interimOffset(frame: 271000..<272500, document: 0..<272500, current: 271900,
                                                 target: 271950, viewport: viewport) == nil)
    }
}

/// qa11 wt-fling-c/d (build 2e205166, 4 black runs of 3 source frames in 120
/// jumps, the scroll indicator already at the bottom): while the jump waited,
/// viewport requests still followed the page's offset (the reader's rows):
/// a scrollbar report or the composer's inset change asked Ghostty for the
/// reader's rows again after the end had been asked for. The end's frame was
/// placed and the page moved, then the reader's frame came, was placed at the
/// reader's rows, and the page at the end had nothing under it for 3 frames.
/// While a move waits, every viewport request is for its target's rows; past
/// the maximum wait the page goes to the placed frame's rows nearest the
/// target, never to rows no frame covers.
@Suite struct TerminalScrollGateRequestTests {
    @Test func aWaitingMoveAsksOnlyForItsTargetsRows() {
        #expect(TerminalScrollGate.requestOffset(awaiting: true, current: 250_000, target: 273_000) == 273_000)
        #expect(TerminalScrollGate.requestOffset(awaiting: false, current: 250_000, target: 273_000) == 250_000)
        #expect(TerminalScrollGate.requestOffset(awaiting: true, current: 250_000, target: nil) == 250_000)
    }

    @Test func pastTheMaximumWaitThePageGoesToTheFramesRowsNearestTheTarget() {
        #expect(TerminalScrollGate.fallbackOffset(frame: 270_000..<272_400, target: 271_700, viewport: 800) == 271_600)
        #expect(TerminalScrollGate.fallbackOffset(frame: 250_000..<252_400, target: 271_700, viewport: 800) == 251_600)
        #expect(TerminalScrollGate.fallbackOffset(frame: 270_000..<272_400, target: 260_000, viewport: 800) == 270_000)
    }
}
