import CoreGraphics
import Foundation

/// Ghostty prunes its oldest scrollback rows a page at a time once the
/// scrollback is at its cap: the total drops by hundreds of rows, and a
/// viewport in the scrollback keeps its rows, so its reported top drops by
/// the same count. Every absolute row the phone holds (the reading anchor,
/// the presented and requested viewport tops, the document, the scroll
/// offset) must move up by it, or a reset reads the mark at the old row
/// number, rows lower in the text (VERIFY-round5 V2-3), and a fling over the
/// shorter document runs into its end (V5-2).
struct TerminalHistoryPrune {
    /// The rows pruned between two scrollbar reports, or nil when the change
    /// is something else: a request of ours (the old report was not the one
    /// asked for, or the history did not shrink), a `clear` (the history is
    /// gone), a viewport that followed the output, or a viewport that fell
    /// by far more than the history shrank.
    static func prunedRows(previousTotal: Int, previousOffset: Int, total: Int, offset: Int,
                           requestedTop: Int, rows: Int) -> Int? {
        // Following (VERIFY-round8 claim 1b): the viewport is the active area
        // before and after, so it moved with the end, not with the rows. The
        // frame on screen (the old end) is the total's shrink higher in the
        // new numbering: that is how far everything held moves up, so the
        // page shows the same frame at the same place until the next present
        // (the rows appended meanwhile are not in that frame yet).
        if previousOffset == previousTotal - rows, offset == total - rows, total < previousTotal, total > rows {
            return previousTotal - total
        }
        guard previousOffset == requestedTop, total < previousTotal, total > rows,
              previousOffset < previousTotal - rows else { return nil }
        let pruned = previousOffset - offset
        guard pruned > 0 else { return nil }
        // pruned = shrink + rows appended meanwhile: the prune dominates.
        let appended = pruned - (previousTotal - total)
        guard appended >= 0, appended * 2 <= pruned else { return nil }
        return pruned
    }
}

/// The rows of the frame on screen (the surface's viewport, placed at
/// `presentedTop`). A scroll whose visible rows it does not cover would show
/// the page's black background until Ghostty presents a frame for them
/// (VERIFY-round5 V5-1), so it waits for that frame.
struct TerminalFrameCover: Equatable {
    var presentedTop: Int
    var surfaceRows: Int

    func covers(visibleTop: Int, visibleBottom: Int) -> Bool {
        visibleTop >= presentedTop && visibleBottom <= presentedTop + surfaceRows
    }

    /// None of the visible rows are in the frame: a jump, not a step.
    func isDisjoint(visibleTop: Int, visibleBottom: Int) -> Bool {
        visibleBottom <= presentedTop || visibleTop >= presentedTop + surfaceRows
    }
}

/// When the page may move to a scroll target (VERIFY-round8 claim 1a): only
/// to rows the frame on screen covers. Otherwise the last good frame stays
/// where it is and the move waits for Ghostty's frame for the target, which
/// places itself (`surfacePresented`) before the page moves in the same
/// transaction. A wait that outlives its display-frame fallback keeps the
/// old frame until `maxWait`; only then does the page move regardless (the
/// page goes only as far as that frame's rows reach).
struct TerminalScrollGate {
    /// The longest a move waits for its frame (T-SCROLL-09: the bottom within 400 ms of the tap).
    static let maxWait: TimeInterval = 0.3

    /// The frame on screen covers the target's visible rows (rows outside
    /// the document are the page's own background).
    static func movesNow(cover: TerminalFrameCover, visibleTop: Int, visibleBottom: Int, documentRows: Range<Int>) -> Bool {
        TerminalBlankWatch.covers(presentedTop: cover.presentedTop, surfaceRows: cover.surfaceRows, visibleTop: visibleTop,
                                  visibleBottom: visibleBottom, documentRows: documentRows)
    }

    /// While a move waits (qa11 wt-fling-b): Ghostty's new frame replaced
    /// the one on screen and was placed where its rows belong, and it no
    /// longer covers the page at `current` (content y; `frame` is the
    /// surface's span, `document` the document's, `viewport` the page's
    /// height). The page then goes to the offset nearest `target` whose
    /// rows that frame shows; nil while the frame still covers the page
    /// (keep waiting). Rows outside the document are the page's own
    /// background.
    static func interimOffset(frame: Range<CGFloat>, document: Range<CGFloat>, current: CGFloat, target: CGFloat,
                              viewport: CGFloat) -> CGFloat? {
        func covered(_ y: CGFloat) -> Bool {
            let lower = max(y, document.lowerBound), upper = min(y + viewport, document.upperBound)
            guard upper > lower else { return true }
            return lower >= frame.lowerBound - 0.5 && upper <= frame.upperBound + 0.5
        }
        guard !covered(current) else { return nil }
        let high = max(frame.lowerBound, frame.upperBound - viewport)
        return min(max(target, frame.lowerBound), high)
    }

    /// A wait reached its display-frame limit: move now? Only to rows the
    /// frame on screen covers, however long the wait (qa11 wt-fling-c/d: the
    /// forced move at `maxWait` showed 3 black frames). Past `maxWait` the
    /// page goes to the frame's rows nearest the target (`fallbackOffset`).
    static func fallbackMoves(covered: Bool, waited: TimeInterval) -> Bool {
        covered
    }

    /// The offset a viewport request is made for: while a move waits, its
    /// target's rows (qa11 wt-fling-c/d: a report or an inset change asked
    /// again for the reader's rows after the end was asked for, and that
    /// frame then replaced the end's under a page already at the end).
    static func requestOffset(awaiting: Bool, current: CGFloat, target: CGFloat?) -> CGFloat {
        guard awaiting, let target else { return current }
        return target
    }

    /// Past `maxWait`: the offset nearest `target` whose rows the frame on
    /// screen (`frame`, content y) shows, so the page makes progress without
    /// leaving the rows it has.
    static func fallbackOffset(frame: Range<CGFloat>, target: CGFloat, viewport: CGFloat) -> CGFloat {
        min(max(target, frame.lowerBound), max(frame.lowerBound, frame.upperBound - viewport))
    }
}
