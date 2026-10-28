import AppKit
@testable import CmuxNextDesign
import Testing

/// The sidebar and every scrollable card share one thin scroller, the chat's (2026-10-21): a 3 pt
/// rounded knob on no track, an overlay that never takes width. By default it fades at rest
/// (Lawrence 2026-10-23, ThinScrollerFadeTests); the opt-out keeps it shown while the content
/// overflows.
@MainActor
@Suite(.serialized)
struct ThinScrollerTests {
    /// A scroller whose content is four times its height, scrolled to the top.
    private static func overflowing(autoHides: Bool = false) -> ThinScroller {
        let scroller = ThinScroller(frame: NSRect(x: 0, y: 0, width: ThinScroller.width, height: 200))
        scroller.scrollerStyle = .overlay
        scroller.isEnabled = true // a scroll view enables its scroller when the content overflows
        scroller.autoHides = autoHides
        scroller.knobProportion = 0.25
        scroller.doubleValue = 0
        return scroller
    }

    @Test func aScrollViewGetsTheSharedThinScroller() throws {
        defer { SystemScrollers.preferredStyleOverride = nil }
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.hasVerticalScroller = true
        SystemScrollers.followThin(scrollView)
        let scroller = try #require(scrollView.verticalScroller as? ThinScroller)
        #expect(ThinScroller.knobThickness == 3)
        #expect(ThinScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay) <= 12)
        #expect(ThinScroller.isCompatibleWithOverlayScrollers)
        #expect(scroller.knobRect(for: CGRect(x: -2, y: 10, width: 6, height: 40)).width == ThinScroller.knobThickness)
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.autohidesScrollers)
        SystemScrollers.preferredStyleOverride = .legacy
        SystemScrollers.systemStyleDidChange()
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.verticalScroller is ThinScroller)
    }

    @Test func theKnobStaysShownWhileTheContentOverflows() throws {
        let scroller = Self.overflowing()
        let knob = try #require(scroller.restingKnobFrame)
        #expect(knob.width == ThinScroller.knobThickness)
        #expect(knob.height > 0)
        #expect(knob.minX >= scroller.bounds.minX)
        #expect(knob.maxX == scroller.bounds.maxX - 2) // 2 pt in from the trailing edge
        // It follows the scroll position.
        scroller.doubleValue = 1
        let moved = try #require(scroller.restingKnobFrame)
        #expect(moved.minY != knob.minY)
        #expect(moved.width == ThinScroller.knobThickness)
    }

    @Test func nothingToScrollShowsNoKnob() {
        let scroller = Self.overflowing()
        scroller.knobProportion = 1
        #expect(scroller.restingKnobFrame == nil)
    }

    @Test func autoHideHidesTheKnobAtRest() {
        defer { SystemScrollers.thinScrollersAutoHide = true }
        let scroller = Self.overflowing(autoHides: true)
        #expect(scroller.restingKnobFrame == nil)
        scroller.autoHides = false
        #expect(scroller.restingKnobFrame != nil)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.hasVerticalScroller = true
        SystemScrollers.followThin(scrollView)
        #expect((scrollView.verticalScroller as? ThinScroller)?.autoHides == true) // the default
        SystemScrollers.thinScrollersAutoHide = false
        #expect((scrollView.verticalScroller as? ThinScroller)?.autoHides == false)
        SystemScrollers.thinScrollersAutoHide = true
        #expect((scrollView.verticalScroller as? ThinScroller)?.autoHides == true)
    }

    @Test func noTrackIsDrawn() throws {
        let scroller = Self.overflowing()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 7, pixelsHigh: 200, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        scroller.drawKnobSlot(in: scroller.bounds, highlight: true)
        scroller.drawKnobSlot(in: scroller.bounds, highlight: false)
        // The knob, in its own view, is drawn by that view alone: the scroller's knob draws nothing.
        scroller.drawKnob()
        NSGraphicsContext.current?.flushGraphics()
        var painted = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 { painted += 1 }
        }
        #expect(painted == 0)
    }
}
