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
        CEFShimEvent(kind: 52, browser: browser, request: scaleMilli, a: type, b: hotspot, s1: png, s2: "")
    }

    /// A `width` x `height` pixel PNG, as the shim encodes a custom cursor image.
    func png(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func builtInCursorsDecodeToTheirCSSNames() {
        #expect(event(type: 3) == .cursor(browser: 7, cursor: .builtIn(3)))
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
        #expect(decoded == .cursor(browser: 7, cursor: .custom(png: image, scale: 2, hotspotX: 6, hotspotY: 9)))
        #expect(CEFPageCursor.custom(png: image, scale: 2, hotspotX: 6, hotspotY: 9).cssName == "custom")

        // Points, as Chrome's CreateCustomCursor sizes it: pixels / scale, the hotspot too.
        let cursor = CEFPageCursor.custom(png: image, scale: 2, hotspotX: 6, hotspotY: 9).makeCursor()
        #expect(cursor.image.size == NSSize(width: 32, height: 16))
        #expect(cursor.hotSpot == NSPoint(x: 3, y: 4.5))
    }

    /// The shim sends the arrow for an image it cannot encode; cmux does the same for one it cannot read.
    @Test func aCustomCursorWithoutAReadableImageIsTheArrow() {
        #expect(event(type: 45, scaleMilli: 1_000, png: "not base64 !") == .cursor(browser: 7, cursor: .arrow))
        #expect(event(type: 45, scaleMilli: 1_000, png: "") == .cursor(browser: 7, cursor: .arrow))
        #expect(event(type: 45, scaleMilli: 0, png: "AAAA") == .cursor(browser: 7, cursor: .arrow))
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
                                        makeLayerHost: { _ in CALayer() }, pageUpdateCenter: NotificationCenter())
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
}
