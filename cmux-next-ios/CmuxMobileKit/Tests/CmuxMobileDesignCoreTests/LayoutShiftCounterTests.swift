import CmuxMobileDesignCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing

/// The layout-shift count's rule (CmuxMobileDesignCore/LayoutShiftCounter.swift). Leo, 2026-11-24: "the
/// loading has layout shifts and placeholder states that likely dont need to be so placeholder and
/// better diffed".
struct LayoutShiftCounterTests {
    private func row(_ y: CGFloat, h: CGFloat = 60, _ space: LayoutShiftCounter.Space = .scrollContent) -> LayoutShiftCounter.Row {
        .init(CGRect(x: 0, y: y, width: 390, height: h), space)
    }

    @Test func nothingCountsBeforeFirstPaintAndAStillScreenIsZero() {
        var counter = LayoutShiftCounter()
        counter.frame([:])
        counter.frame([:])
        #expect(counter.frames == 0)
        for _ in 0..<10 { counter.frame(["a": row(0), "b": row(60)]) }
        #expect(counter.frames == 10)
        #expect(counter.shiftFrames == 0)
    }

    @Test func rowsArrivingAreNotAShiftButARowPushedDownIs() {
        var counter = LayoutShiftCounter()
        counter.frame(["a": row(0)])
        counter.frame(["a": row(0), "b": row(60)])
        #expect(counter.shiftFrames == 0)
        // A banner lands above both: each drawn row moves down, in its scroll content.
        #expect(counter.frame(["banner": row(0, h: 44), "a": row(44), "b": row(104)]) == 2)
        #expect(counter.shiftFrames == 1)
        #expect(counter.shiftedRows == 2)
        #expect(counter.lastMoved == "a 0/60->44/60")
    }

    @Test func aRowThatGrowsIsAShift() {
        var counter = LayoutShiftCounter()
        counter.frame(["a": row(0, h: 44)])
        counter.frame(["a": row(0, h: 120)])
        #expect(counter.shiftFrames == 1)
    }

    private func streamed(_ y: CGFloat, h: CGFloat, _ revision: Int) -> LayoutShiftCounter.Row {
        .init(CGRect(x: 0, y: y, width: 390, height: h), .window, content: revision)
    }

    /// A streamed answer at the bottom of a transcript that follows it (heavy duress plays one into
    /// every chat): the answer grows with each token and the scroll keeps its bottom in view, so the
    /// rows above ride the scroll. New content is not a shift; a resize at the same revision is.
    @Test func aRowGrowingWithNewContentIsNotAShiftButTheSameRevisionResizingIs() {
        var counter = LayoutShiftCounter()
        counter.frame(["q": streamed(300, h: 120, 1), "a": streamed(420, h: 49, 1)])
        // Following: the answer's bottom holds, its top and the row above move up by 54.
        counter.frame(["q": streamed(246, h: 120, 1), "a": streamed(366, h: 103, 2)])
        #expect(counter.shiftFrames == 0)
        // Not following: the answer grows downward, its top holds, nothing else moves.
        counter.frame(["q": streamed(246, h: 120, 1), "a": streamed(366, h: 180, 3)])
        #expect(counter.shiftFrames == 0)
        // The revision landed a frame before its layout: still new content.
        counter.frame(["q": streamed(246, h: 120, 1), "a": streamed(366, h: 180, 4)])
        counter.frame(["q": streamed(246, h: 120, 1), "a": streamed(366, h: 220, 4)])
        #expect(counter.shiftFrames == 0)
        // The same revision measured again (an estimate corrected late) is a shift.
        counter.frame(["q": streamed(246, h: 120, 1), "a": streamed(366, h: 260, 4)])
        #expect(counter.shiftFrames == 1)
    }

    /// The rows a growing row pushes still count, and so does a growing row both of whose edges
    /// moved against the scroll.
    @Test func whatNewContentPushesStillCounts() {
        var counter = LayoutShiftCounter()
        counter.frame(["a": streamed(100, h: 49, 1), "b": streamed(149, h: 60, 1)])
        #expect(counter.frame(["a": streamed(100, h: 103, 2), "b": streamed(203, h: 60, 1)]) == 1)
        #expect(counter.lastMoved == "b 149/60->203/60")
        counter.frame(["a": streamed(80, h: 160, 3)])
        #expect(counter.shiftFrames == 2)
    }

    /// While an answer streams and the transcript follows it, a row above the answer changing
    /// height at its own revision is a real shift, so the counter cannot go quiet under streaming.
    @Test func aRowAboveAStreamingAnswerChangingHeightStillCounts() {
        var counter = LayoutShiftCounter()
        counter.frame(["q": streamed(200, h: 100, 1), "p": streamed(300, h: 120, 1), "a": streamed(420, h: 49, 1)])
        // The answer grows (new revision) while the row above it is re-measured at the same one.
        counter.frame(["q": streamed(146, h: 100, 1), "p": streamed(246, h: 160, 1), "a": streamed(406, h: 63, 2)])
        #expect(counter.shiftFrames == 1)
        #expect(counter.moves.contains { $0.contains("p 300/120->246/160") })
    }

    /// Without a revision (a SwiftUI row, an older list) a resize counts as before.
    @Test func aRowWithoutARevisionGrowingIsAShift() {
        var counter = LayoutShiftCounter()
        counter.frame(["a": row(0, h: 49, .window)])
        counter.frame(["a": row(0, h: 103, .window)])
        #expect(counter.shiftFrames == 1)
    }

    @Test func subPointJitterIsNotAShift() {
        var counter = LayoutShiftCounter()
        counter.frame(["a": row(0)])
        counter.frame(["a": row(0.6)])
        #expect(counter.shiftFrames == 0)
    }

    @Test func aScrollOfWindowRowsIsNotAShiftButOneRowMovingAgainstItIs() {
        var counter = LayoutShiftCounter()
        counter.frame(["a": row(100, .window), "b": row(160, .window), "c": row(220, .window)])
        counter.frame(["a": row(40, .window), "b": row(100, .window), "c": row(160, .window)])
        #expect(counter.shiftFrames == 0)
        // Scrolling on, while row c also grows taller than its estimate.
        counter.frame(["a": row(0, .window), "b": row(60, .window), "c": row(120, h: 200, .window)])
        #expect(counter.shiftFrames == 1)
        #expect(counter.shiftedRows == 1)
    }

    @Test func rowsOneScrollMovedEitherSideOfABucketEdgeAreTheScroll() {
        var counter = LayoutShiftCounter()
        counter.frame(["a": row(100, .window), "b": row(160, .window), "c": row(220, .window)])
        // A decelerating scroll: -2.9 and -3.1 pt round to different 2 pt buckets, but are one scroll.
        counter.frame(["a": row(97.1, .window), "b": row(157.1, .window), "c": row(216.9, .window)])
        #expect(counter.shiftFrames == 0)
        // A row 3 pt off the scroll still counts.
        counter.frame(["a": row(94.2, .window), "b": row(154.2, .window), "c": row(211, .window)])
        #expect(counter.shiftFrames == 1)
        #expect(counter.lastMoved == "c 216/60->211/60")
        #expect(counter.moves == ["3:c 216/60->211/60 dy -5.9 dh 0.0 scroll -2.9"])
    }

    /// The workspaces flow at 123de7a6 under duress=heavy: a streamed answer alone on screen,
    /// followed, grew 76 -> 157 pt while the list scrolled 42 pt; with no other row to read the
    /// scroll from, it counted. Its list's own scroll says what moved it.
    @Test func aFollowedAnswerAloneOnScreenIsReadAgainstItsListsScroll() {
        var counter = LayoutShiftCounter()
        counter.frame(["m": .init(CGRect(x: 0, y: 623, width: 390, height: 76), .window, content: 1, scrolled: .zero)])
        counter.frame(["m": .init(CGRect(x: 0, y: 581, width: 390, height: 157), .window, content: 2, scrolled: CGPoint(x: 0, y: -42))])
        #expect(counter.shiftFrames == 0)
        // Without the list's scroll, the same frame counts (both edges moved).
        var blind = LayoutShiftCounter()
        blind.frame(["m": streamed(623, h: 76, 1)])
        blind.frame(["m": streamed(581, h: 157, 2)])
        #expect(blind.shiftFrames == 1)
    }

    /// A row alone on screen moving by its list's scroll is the scroll; moving otherwise, or the
    /// list not scrolling, is a shift.
    @Test func aLoneRowIsTheScrollOnlyWhenItMovedByItsListsScroll() {
        var counter = LayoutShiftCounter()
        let lone = { (y: CGFloat, by: CGFloat) in ["a": LayoutShiftCounter.Row(CGRect(x: 0, y: y, width: 390, height: 44), .window, scrolled: CGPoint(x: 0, y: by))] }
        counter.frame(lone(700, 0))
        counter.frame(lone(650, -50))
        #expect(counter.shiftFrames == 0)
        // Pushed down 54 pt with the list still: content landed above it.
        counter.frame(lone(704, 0))
        #expect(counter.shiftFrames == 1)
        // Moved 30 pt against a 10 pt scroll.
        counter.frame(lone(664, -10))
        #expect(counter.shiftFrames == 2)
    }

    /// A pushed row's record names what landed above it, so a run's log says the cause.
    @Test func aPushedRowsRecordNamesWhatLandedAboveIt() {
        var counter = LayoutShiftCounter()
        counter.frame(["a": row(0), "b": row(60)])
        counter.frame(["a": row(0), "card": row(60, h: 54), "b": row(114)])
        #expect(counter.moves == ["2:b 60/60->114/60 under new card"])
    }

    /// The late edited-files card (step c7678e3e): `f` lands above a finished turn's actions row
    /// `a`. Unheld, the list keeps its offset and `a` is pushed 238 pt down; held (the list holds
    /// the bottom row the reader sees), `a` stays and the row above moves up with the list's scroll.
    @Test func aRowInsertedAboveTheReaderIsNotAShiftWhenTheListHoldsTheRowsUnderIt() {
        let w = { (y: CGFloat, h: CGFloat, by: CGFloat) in
            LayoutShiftCounter.Row(CGRect(x: 0, y: y, width: 390, height: h), .window, scrolled: CGPoint(x: 0, y: by))
        }
        var held = LayoutShiftCounter()
        held.frame(["u": w(457, 64, 0), "a": w(633, 44, 0)])
        held.frame(["u": w(219, 64, -238), "f": w(395, 230, -238), "a": w(633, 44, -238)])
        #expect(held.shiftFrames == 0)

        var pushed = LayoutShiftCounter()
        pushed.frame(["u": w(457, 64, 0), "a": w(633, 44, 0)])
        pushed.frame(["u": w(457, 64, 0), "f": w(529, 230, 0), "a": w(871, 44, 0)])
        #expect(pushed.shiftFrames == 1)
        #expect(pushed.moves == ["2:a 633/44->871/44 dy 238.0 dh 0.0 list 0.0 under new f"])
    }

    @Test func aRowThatLeavesAndComesBackIsComparedOnlyWhileDrawn() {
        var counter = LayoutShiftCounter()
        counter.frame(["a": row(0)])
        counter.frame([:])
        counter.frame(["a": row(500)])
        #expect(counter.shiftFrames == 0)
    }
}
