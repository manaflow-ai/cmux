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

    @Test func aRowThatLeavesAndComesBackIsComparedOnlyWhileDrawn() {
        var counter = LayoutShiftCounter()
        counter.frame(["a": row(0)])
        counter.frame([:])
        counter.frame(["a": row(500)])
        #expect(counter.shiftFrames == 0)
    }
}
