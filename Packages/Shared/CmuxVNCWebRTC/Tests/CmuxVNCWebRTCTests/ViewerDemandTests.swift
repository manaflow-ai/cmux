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
        let changed1 = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 0)
        #expect(!changed1)
        let changed2 = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 4)
        #expect(!changed2)
        #expect(demand.cap == nil)
        let changed3 = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 6)
        #expect(changed3)
        #expect(demand.cap == 1280)
        let changed4 = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 8)
        #expect(!changed4, "no change while it holds")
    }

    @Test func aContradictedReportRestartsTheHold() {
        var demand = ViewerDemand()
        _ = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 0)
        _ = demand.report(longEdge: 2000, displayLongEdge: display, pinch: false, now: 2)
        let changed5 = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 6)
        #expect(!changed5, "the clock started again at 6")
        let changed6 = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 12)
        #expect(changed6)
        #expect(demand.cap == 1280)
    }

    @Test func aLargerPictureHoldsThreeSecondsOrSixAfterARecentStepDown() {
        var demand = ViewerDemand()
        _ = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 0)
        _ = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 6)
        #expect(demand.cap == 1280)
        // Within 30 s of the step down: 6 s.
        _ = demand.report(longEdge: 2000, displayLongEdge: display, pinch: false, now: 10)
        let changed7 = demand.report(longEdge: 2000, displayLongEdge: display, pinch: false, now: 14)
        #expect(!changed7)
        let changed8 = demand.report(longEdge: 2000, displayLongEdge: display, pinch: false, now: 16)
        #expect(changed8)
        #expect(demand.cap == 2560)
        // A raise after a raise: 3 s.
        _ = demand.report(longEdge: 3400, displayLongEdge: display, pinch: false, now: 20)
        let changed9 = demand.report(longEdge: 3400, displayLongEdge: display, pinch: false, now: 23)
        #expect(changed9)
        #expect(demand.cap == nil, "full size")
    }

    @Test func aPinchRaisesAtOnce() {
        var demand = ViewerDemand()
        _ = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 0)
        _ = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 6)
        let changed10 = demand.report(longEdge: 3600, displayLongEdge: display, pinch: true, now: 7)
        #expect(changed10)
        #expect(demand.cap == nil)
        // A pinch out still waits the 6 s.
        let changed11 = demand.report(longEdge: 1179, displayLongEdge: display, pinch: true, now: 8)
        #expect(!changed11)
        #expect(demand.cap == nil)
    }

    @Test func aReportWithNoSizeChangesNothing() {
        var demand = ViewerDemand()
        _ = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 0)
        let changed12 = demand.report(longEdge: 0, displayLongEdge: display, pinch: false, now: 3)
        #expect(!changed12)
        let changed13 = demand.report(longEdge: 1179, displayLongEdge: display, pinch: false, now: 7)
        #expect(!changed13, "the pending step was dropped")
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

    /// Only a source that scales gets the cap: the Screen Sharing loopback
    /// keeps sending the full display, so its bitrate keeps the full size.
    @Test func onlyAScalingSourceTakesTheCap() {
        #expect(ScreenStreamHost.captureCap(1280, quality: .auto, scales: true) == 1280)
        #expect(ScreenStreamHost.captureCap(1280, quality: .smooth, scales: true) == 1280)
        #expect(ScreenStreamHost.captureCap(1280, quality: .auto, scales: false) == nil, "a loopback source")
        #expect(ScreenStreamHost.captureCap(nil, quality: .auto, scales: true) == nil)
        #expect(ScreenStreamHost.captureCap(1280, quality: .high, scales: true) == nil, "a fixed preset")
        #expect(!RecordingBackend().scalesToDemand, "a source scales only when it says so")
    }

    /// The viewer's report goes as a `view` message the host reads, never as input.
    @Test func theReportIsAViewMessage() throws {
        let input = ScreenInput(t: ScreenStreamViewer.viewDemandMessage, d: true, i: 1280)
        let decoded = try JSONDecoder().decode(ScreenInput.self, from: JSONEncoder().encode(input))
        #expect(decoded.t == "view" && decoded.i == 1280 && decoded.d == true)
    }
}
