import AppKit
@testable import CmuxNextBrowser
import Testing

/// Task 045 of plans/cmux-next/chrome-parity/p01-process.md: a page's cursor reaches cmux as
/// CURSOR (the type, or a CSS cursor image as PNG with its scale and hotspot) and the page view
/// shows it as an NSCursor over the page.
@MainActor
@Suite struct CEFPageCursorTests {
    /// A CURSOR event's fields, as the shim emits them (CEFShim/src/cursor_event.h).
    func event(browser: Int32 = 7, type: Int64, scaleMilli: Int32 = 0, hotspot: Int64 = 0, png: String = "") -> CEFShimEvent {
        CEFShimEvent(kind: 54, browser: browser, request: scaleMilli, a: type, b: hotspot, s1: png, s2: "")
    }

    /// A `width` x `height` pixel PNG, as the shim encodes a custom cursor image.
    func png(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func builtInCursorsDecodeToTheirCSSNames() {
        #expect(event(type: 3) == .pageView(browser: 7, .cursor(.builtIn(3))))
        #expect(CEFPageCursor.builtIn(0).cssName == "default")
        #expect(CEFPageCursor.builtIn(2).cssName == "pointer")
        #expect(CEFPageCursor.builtIn(3).cssName == "text")
        #expect(CEFPageCursor.builtIn(18).cssName == "col-resize")
        #expect(CEFPageCursor.builtIn(19).cssName == "row-resize")
        #expect(CEFPageCursor.builtIn(42).cssName == "grabbing")
        #expect(CEFPageCursor.builtIn(49).cssName == "alias")
        #expect(CEFPageCursor.builtIn(50).cssName == "default", "past CT_DND_LINK")
        #expect(CEFPageCursor.builtIn(-1).cssName == "default")
        // One name per cef_cursor_type_t value up to CT_DND_LINK, CT_CUSTOM at 45.
        #expect(CEFPageCursor.cssNames.count == 50)
        #expect(CEFPageCursor.cssNames[Int(CEFPageCursor.customType)] == "custom")
    }

    @Test func aCustomCursorCarriesItsImageScaleAndHotspot() throws {
        let image = try png(width: 64, height: 32)
        let hotspot = (Int64(9) << 32) | 6
        let decoded = event(type: 45, scaleMilli: 2_000, hotspot: hotspot, png: image.base64EncodedString())
        #expect(decoded == .pageView(browser: 7, .cursor(.custom(png: image, scale: 2, hotspotX: 6, hotspotY: 9))))
        #expect(CEFPageCursor.custom(png: image, scale: 2, hotspotX: 6, hotspotY: 9).cssName == "custom")

        // Points, as Chrome's CreateCustomCursor sizes it: pixels / scale, the hotspot too.
        let cursor = CEFPageCursor.custom(png: image, scale: 2, hotspotX: 6, hotspotY: 9).makeCursor()
        #expect(cursor.image.size == NSSize(width: 32, height: 16))
        #expect(cursor.hotSpot == NSPoint(x: 3, y: 4.5))
    }

    /// The shim sends the arrow for an image it cannot encode; cmux does the same for one it cannot read.
    @Test func aCustomCursorWithoutAReadableImageIsTheArrow() {
        #expect(event(type: 45, scaleMilli: 1_000, png: "not base64 !") == .pageView(browser: 7, .cursor(.arrow)))
        #expect(event(type: 45, scaleMilli: 1_000, png: "") == .pageView(browser: 7, .cursor(.arrow)))
        #expect(event(type: 45, scaleMilli: 0, png: "AAAA") == .pageView(browser: 7, .cursor(.arrow)))
        let garbage = CEFPageCursor.custom(png: Data([1, 2, 3]), scale: 1, hotspotX: 0, hotspotY: 0)
        #expect(garbage.makeCursor() === NSCursor.arrow)
    }

    @Test func builtInCursorsAreAppKitsOwn() {
        #expect(CEFPageCursor.builtIn(0).makeCursor() === NSCursor.arrow)
        #expect(CEFPageCursor.builtIn(2).makeCursor() === NSCursor.pointingHand)
        #expect(CEFPageCursor.builtIn(3).makeCursor() === NSCursor.iBeam)
        #expect(CEFPageCursor.builtIn(41).makeCursor() === NSCursor.openHand)
        #expect(CEFPageCursor.builtIn(38).makeCursor() === NSCursor.operationNotAllowed)
        let columnResize: NSCursor
        if #available(macOS 15, *) { columnResize = .columnResize } else { columnResize = .resizeLeftRight }
        #expect(CEFPageCursor.builtIn(18).makeCursor() === columnResize)
        // No public macOS cursor: the arrow, never a wrong shape.
        #expect(CEFPageCursor.builtIn(4).makeCursor() === NSCursor.arrow, "wait")
        #expect(CEFPageCursor.builtIn(29).makeCursor() === NSCursor.arrow, "move")
    }

    /// The page view shows the page's cursor over the page and nothing in process (no CURSOR there:
    /// the page window shows Chromium's cursor).
    @Test func thePageViewCoversThePageWithItsCursor() {
        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), inputTarget: .view,
                                        makeLayerHost: { _ in CALayer() }, windowEventCenter: NotificationCenter())
        #expect(page.pageCursor == nil)
        #expect(page.shownCursor == nil)
        #expect(page.pageCursorName == nil)

        page.pageCursor = .builtIn(3)
        #expect(page.shownCursor === NSCursor.iBeam)
        #expect(page.pageCursorName == "text")
        page.pageCursor = .builtIn(2)
        #expect(page.shownCursor === NSCursor.pointingHand)
        page.pageCursor = nil
        #expect(page.shownCursor == nil)

        let container = NSView(frame: page.frame)
        container.addSubview(page)
        #expect(ChromiumHostPageView.first(in: container) === page)
        #expect(ChromiumHostPageView.first(in: NSView()) == nil)
    }

    /// The cursor rects are the visible page less the holes: they never overlap, never reach into a
    /// hole, and cover the rest of the page.
    @Test func cursorRectsLeaveOutTheHoles() {
        let page = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(ChromiumHostPageView.uncovered(page, by: []) == [page])
        #expect(ChromiumHostPageView.uncovered(page, by: [CGRect(x: 400, y: 0, width: 10, height: 10)]) == [page])
        #expect(ChromiumHostPageView.uncovered(page, by: [page.insetBy(dx: -5, dy: -5)]).isEmpty)
        #expect(ChromiumHostPageView.uncovered(.zero, by: []).isEmpty)

        // A find bar at the top right, a divider grab down the left edge, overlapping a prompt bar at the bottom.
        let holes = [CGRect(x: 180, y: 160, width: 110, height: 30), CGRect(x: 0, y: 0, width: 6, height: 200),
                     CGRect(x: 0, y: 0, width: 300, height: 24)]
        let rects = ChromiumHostPageView.uncovered(page, by: holes)
        for (index, rect) in rects.enumerated() {
            #expect(page.contains(rect))
            #expect(!holes.contains { $0.intersects(rect) }, "\(rect) reaches into a hole")
            #expect(!rects.enumerated().contains { $0.offset != index && $0.element.intersects(rect) }, "\(rect) overlaps")
        }
        let area: CGFloat = rects.reduce(0) { $0 + $1.width * $1.height }
        // 300 x 200, less the grab (6 x 176 above the prompt bar), the prompt bar (300 x 24) and the find bar (110 x 30).
        let expected: CGFloat = 300 * 200 - 6 * 176 - 300 * 24 - 110 * 30
        #expect(area == expected)
    }

    /// A window that counts the cursor-rect invalidations it is asked for.
    final class CursorRectCountingWindow: NSWindow {
        private(set) var cursorRectInvalidations = 0

        override func invalidateCursorRects(for view: NSView) {
            cursorRectInvalidations += 1
            super.invalidateCursorRects(for: view)
        }
    }

    /// The page cursor lives in `.cursorUpdate` areas over the uncovered pieces: a divider
    /// grab moving over the page on each of 20 drag frames swaps the areas and invalidates none of the
    /// window's cursor rects, where each move rebuilt them before. No cursor: no areas.
    @Test func aHoleMovingEveryFrameRebuildsNoCursorRects() throws {
        let window = CursorRectCountingWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless],
                                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = container
        let page = ChromiumHostPageView(frame: container.bounds, inputTarget: .view,
                                        makeLayerHost: { _ in CALayer() }, windowEventCenter: NotificationCenter())
        container.addSubview(page)
        page.updateTrackingAreas()
        #expect(page.cursorAreas.isEmpty, "no page cursor yet")

        page.pageCursor = .builtIn(3)
        #expect(page.cursorAreas.map(\.rect) == [page.visibleRect])
        let before = window.cursorRectInvalidations
        for frame in 1...20 {
            let grab = CGRect(x: 100 + CGFloat(frame) * 3, y: 0, width: 6, height: 200)
            page.cursorHoles = [grab]
            let rects = page.cursorAreas.map(\.rect)
            #expect(rects == ChromiumHostPageView.uncovered(page.visibleRect, by: [grab]))
            #expect(!rects.contains { $0.intersects(grab) }, "a cursor area reaches into the grab")
            #expect(page.cursorAreas.allSatisfy { $0.options.contains(.cursorUpdate) && $0.options.contains(.activeInKeyWindow) })
        }
        #expect(window.cursorRectInvalidations == before,
                "cursor rects invalidated while the grab moved: \(window.cursorRectInvalidations - before)")

        let crash = NSView()
        #expect(page.setCrashOverlay(crash))
        #expect(page.cursorAreas.isEmpty, "the crash page covers the whole page")
        #expect(page.setCrashOverlay(nil))
        #expect(!page.cursorAreas.isEmpty)
        page.pageCursor = nil
        #expect(page.cursorAreas.isEmpty, "no page cursor: AppKit's")
        #expect(!page.trackingAreas.contains { $0.options.contains(.cursorUpdate) })
    }

    /// Host mode: the page view's cursor holes follow its host view's occlusion rects (the find bar and
    /// prompt bar over the page), and the crash page covers all of it.
    @Test func thePageCursorNeverShowsOverNativeUIOnThePage() {
        let host = CEFHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let page = ChromiumHostPageView(frame: host.bounds, inputTarget: .pageWindow,
                                        makeLayerHost: { _ in CALayer() }, windowEventCenter: NotificationCenter())
        host.addSubview(page, positioned: .below, relativeTo: nil)
        let findBar = CGRect(x: 180, y: 160, width: 110, height: 30)
        host.occlusionRects = [findBar]
        #expect(page.cursorHoles == [findBar])
        #expect(page.coveredRects == [findBar])
        host.occlusionRects = []
        #expect(page.cursorHoles.isEmpty)

        let crash = NSView()
        #expect(page.setCrashOverlay(crash) == false, "a page window page shows no crash overlay")
        let hosted = ChromiumHostPageView(frame: host.bounds, inputTarget: .view,
                                          makeLayerHost: { _ in CALayer() }, windowEventCenter: NotificationCenter())
        #expect(hosted.setCrashOverlay(crash))
        #expect(hosted.coveredRects == [hosted.bounds])
        #expect(ChromiumHostPageView.uncovered(hosted.bounds, by: hosted.coveredRects).isEmpty)
    }
}
