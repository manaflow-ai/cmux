@testable import CmuxVNCWebRTC
import CoreGraphics
import Foundation
import Testing

/// Viewer demand (Petal's ladder): the host captures at the smallest rung
/// that covers what the viewer shows, after the change held long enough.
struct ViewerDemandTests {
    /// A 16" MacBook Pro's display.
    let display = 3456

    @Test func theRungCoversTheViewer() {
        #expect(ViewerDemand.rung(for: 1179, displayLongEdge: display) == 1280, "an iPhone at fit")
        #expect(ViewerDemand.rung(for: 960, displayLongEdge: display) == 960)
        #expect(ViewerDemand.rung(for: 400, displayLongEdge: display) == 960)
        #expect(ViewerDemand.rung(for: 2000, displayLongEdge: display) == 2560)
        #expect(ViewerDemand.rung(for: 3000, displayLongEdge: display) == nil, "3840 is more than the display: full size")
        #expect(ViewerDemand.rung(for: 9000, displayLongEdge: 5120) == 3840)
        #expect(ViewerDemand.rung(for: 1000, displayLongEdge: 1080) == nil, "a rung above the display is full size")
    }

    @Test func aSmallerPictureAppliesAfterSixSeconds() {
        var demand = ViewerDemand()
        #expect(!demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 0))
        #expect(!demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 4))
        #expect(demand.cap == nil)
        #expect(demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 6))
        #expect(demand.cap == 1280)
        #expect(!demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 8), "no change while it holds")
    }

    @Test func aContradictedReportRestartsTheHold() {
        var demand = ViewerDemand()
        _ = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 0)
        _ = demand.report(longEdge: 2000, displayLongEdge: display, pinch: false, now: 2)
        #expect(!demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 6), "the clock started again at 6")
        #expect(demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 12))
        #expect(demand.cap == 1280)
    }

    @Test func aLargerPictureHoldsThreeSecondsOrSixAfterARecentStepDown() {
        var demand = ViewerDemand()
        _ = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 0)
        _ = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 6)
        #expect(demand.cap == 1280)
        // Within 30 s of the step down: 6 s.
        _ = demand.report(longEdge: 2000, displayLongEdge: display, pinch: false, now: 10)
        #expect(!demand.report(longEdge: 2000, displayLongEdge: display, pinch: false, now: 14))
        #expect(demand.report(longEdge: 2000, displayLongEdge: display, pinch: false, now: 16))
        #expect(demand.cap == 2560)
        // A raise after a raise: 3 s.
        _ = demand.report(longEdge: 3400, displayLongEdge: display, pinch: false, now: 20)
        #expect(demand.report(longEdge: 3400, displayLongEdge: display, pinch: false, now: 23))
        #expect(demand.cap == nil, "full size")
    }

    @Test func aPinchRaisesAtOnce() {
        var demand = ViewerDemand()
        _ = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 0)
        _ = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 6)
        #expect(demand.report(longEdge: 3600, displayLongEdge: display, pinch: true, now: 7))
        #expect(demand.cap == nil)
        // A pinch out still waits the 6 s.
        #expect(!demand.report(longEdge: 1179, displayLongEdge: display, pinch: true, now: 8))
        #expect(demand.cap == nil)
    }

    @Test func aReportWithNoSizeChangesNothing() {
        var demand = ViewerDemand()
        _ = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 0)
        #expect(!demand.report(longEdge: 0, displayLongEdge: display, pinch: false, now: 3))
        #expect(!demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 7), "the pending step was dropped")
        #expect(demand.cap == nil)
    }

    @Test func fitScalesTheLongEdgeAndKeepsEvenSides() {
        let size = CGSize(width: 3456, height: 2234)
        #expect(ViewerDemand.fit(size, cap: nil) == size)
        #expect(ViewerDemand.fit(size, cap: 3840) == size)
        let scaled = ViewerDemand.fit(size, cap: 1280)
        #expect(scaled.width == 1280)
        #expect(scaled.height == 828)
        let portrait = ViewerDemand.fit(CGSize(width: 1080, height: 1920), cap: 960)
        #expect(portrait == CGSize(width: 540, height: 960))
    }

    /// The viewer's report goes as a `view` message the host reads, never as input.
    @Test func theReportIsAViewMessage() throws {
        let input = ScreenInput(t: ScreenStreamViewer.viewDemandMessage, d: true, i: 1280)
        let decoded = try JSONDecoder().decode(ScreenInput.self, from: JSONEncoder().encode(input))
        #expect(decoded.t == "view" && decoded.i == 1280 && decoded.d == true)
    }
}
