import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextWakeupsTestSupport

/// Lawrence 2026-10-23 (msg 12114): "ensure horizontal and vertical scrollbars when there are
/// rows/columns do not have extra bg". A scroll view that scrolls both ways (the Files list and
/// columns, tables) gets the shared thin scroller on both axes: no AppKit track on either bar (the
/// overlay scroller paints one while the pointer is over it), no fill where the two bars meet,
/// and the sideways knob behaves as the vertical one, along the bottom edge.
@MainActor
@Suite(.serialized)
struct ThinScrollerRowsAndColumnsTests {
    /// A scroll view whose content is four times its size both ways, followed by the shared rule.
    private static func rowsAndColumns() -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 800))
        SystemScrollers.follow(scrollView)
        scrollView.tile()
        return scrollView
    }

    /// A sideways scroller in a 240 x 200 host, along its bottom edge, its content four times as wide.
    private static func sideways(in host: NSView) -> ThinScroller {
        // AppKit chooses a scroller's axis from its initial frame; resizing one made at .zero
        // leaves its native knob slot vertical. Initialize the fixture on the axis it exercises.
        let y = host.isFlipped ? host.bounds.maxY - ThinScroller.width : host.bounds.minY
        let scroller = ThinScroller(frame: NSRect(x: 0, y: y, width: host.bounds.width, height: ThinScroller.width),
                                    clock: ManualClock(), notificationCenter: NotificationCenter())
        host.addSubview(scroller)
        scroller.scrollerStyle = .overlay
        scroller.isEnabled = true
        scroller.autoHides = false
        scroller.knobProportion = 0.25
        scroller.doubleValue = 0
        return scroller
    }

    @Test func bothBarsAreTheThinScroller() throws {
        defer { SystemScrollers.preferredStyleOverride = nil }
        let scrollView = Self.rowsAndColumns()
        #expect(scrollView.verticalScroller is ThinScroller)
        #expect(scrollView.horizontalScroller is ThinScroller)
        #expect(scrollView.scrollerStyle == .overlay)
        // "Always" (AppKit resets a scroll view's style then): still overlay, still thin, no corner.
        SystemScrollers.preferredStyleOverride = .legacy
        SystemScrollers.systemStyleDidChange()
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.horizontalScroller is ThinScroller)
        // The opt-out reaches the sideways bar too.
        defer { SystemScrollers.thinScrollersAutoHide = true }
        SystemScrollers.thinScrollersAutoHide = false
        #expect((scrollView.horizontalScroller as? ThinScroller)?.autoHides == false)
    }

    /// A table's header corner (the square above the vertical bar) draws no fill of its own.
    @Test func aTablesHeaderCornerIsGone() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("a")))
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        // Some hosts create no corner. Supply one so this always exercises its removal.
        if table.cornerView == nil { table.cornerView = NSView(frame: NSRect(x: 0, y: 0, width: 11, height: 17)) }
        #expect(table.cornerView != nil)
        SystemScrollers.follow(scrollView)
        #expect(table.cornerView == nil)
    }

    @Test func theSidewaysKnobRunsAlongTheBottomEdge() throws {
        for flipped in [false, true] {
            let frame = NSRect(x: 0, y: 0, width: 240, height: 200)
            let host: NSView = flipped ? FlippedHost(frame: frame) : NSView(frame: frame)
            let scroller = Self.sideways(in: host)
            let knob = try #require(scroller.restingKnobFrame)
            #expect(knob.height == ThinScroller.knobThickness)
            #expect(knob.width > ThinScroller.knobThickness * 4)
            // 2 pt in from the bottom edge, whichever way the scroller's coordinates run.
            let gap = scroller.isFlipped ? scroller.bounds.maxY - knob.maxY : knob.minY - scroller.bounds.minY
            #expect(gap == 2)
            scroller.doubleValue = 1
            let moved = try #require(scroller.restingKnobFrame)
            #expect(moved.minX > knob.minX) // it follows the scroll position sideways
            #expect(moved.height == ThinScroller.knobThickness)
        }
    }

    @Test func thePointerNearTheBottomEdgeWidensTheSidewaysKnob() throws {
        for flipped in [false, true] {
            let frame = NSRect(x: 0, y: 0, width: 240, height: 200)
            let host: NSView = flipped ? FlippedHost(frame: frame) : NSView(frame: frame)
            let scroller = Self.sideways(in: host)
            scroller.autoHides = true
            let bottom = host.isFlipped ? host.bounds.maxY : host.bounds.minY
            let inward: CGFloat = host.isFlipped ? -1 : 1
            scroller.pointerMoved(to: CGPoint(x: 120, y: 100)) // the middle of the view
            #expect(!scroller.isKnobShown)
            scroller.pointerMoved(to: CGPoint(x: 120, y: bottom + inward * (ThinScroller.nearDistance - 4)))
            #expect(scroller.isKnobExpanded)
            #expect(scroller.restingKnobFrame?.height == ThinScroller.expandedKnobThickness)
            // Near the trailing edge but far from the bottom: not this bar's edge.
            scroller.pointerMoved(to: CGPoint(x: host.bounds.maxX - 3, y: 100))
            #expect(!scroller.isKnobShown)
        }
    }

    @Test func theSidewaysBarDrawsNoTrack() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        let scroller = Self.sideways(in: host)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 11, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        scroller.drawKnobSlot(in: scroller.bounds, highlight: true)
        scroller.drawKnobSlot(in: scroller.bounds, highlight: false)
        scroller.drawKnob()
        NSGraphicsContext.current?.flushGraphics()
        var painted = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 { painted += 1 }
        }
        #expect(painted == 0)
    }
}

private final class FlippedHost: NSView {
    override var isFlipped: Bool { true }
}
