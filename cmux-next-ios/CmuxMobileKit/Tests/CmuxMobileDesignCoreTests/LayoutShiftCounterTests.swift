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

    @Test func aRowThatLeavesAndComesBackIsComparedOnlyWhileDrawn() {
        var counter = LayoutShiftCounter()
        counter.frame(["a": row(0)])
        counter.frame([:])
        counter.frame(["a": row(500)])
        #expect(counter.shiftFrames == 0)
    }
}
