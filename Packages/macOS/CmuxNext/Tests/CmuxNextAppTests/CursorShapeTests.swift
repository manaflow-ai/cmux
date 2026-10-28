import AppKit
import CmuxNextDesign
@testable import CmuxNextHomeEngine
@testable import CmuxNextLayout
import Testing

/// A window that counts the cursor-rect invalidations it is asked for: each one makes AppKit rebuild
/// that view's rects at the next event (p04-input-090's "cursor-rect rebuilds per drag frame").
final class CursorRectCountingWindow: NSWindow {
    private(set) var cursorRectInvalidations = 0
    /// The class of each view invalidated, in order (a failure names them).
    private(set) var invalidatedViews: [String] = []

    override func invalidateCursorRects(for view: NSView) {
        cursorRectInvalidations += 1
        invalidatedViews.append(String(describing: type(of: view)))
        super.invalidateCursorRects(for: view)
    }
}

/// Cursors set on entry instead of cursor rects: a view adds one `.cursorUpdate`
/// area over its visible rect and sets its cursor in `cursorUpdate(with:)`, as Chrome's views name
/// the cursor of the view under the pointer (`ui/views/widget/root_view.cc`).
@MainActor @Suite(.serialized) struct CursorShapeTests {
    /// The split divider's cursor area is its cursor rect: the whole handle with no clip, only the part
    /// inside a clip (a dock over the rest, DividerCursorUnderDockTests), so the pointer crossing the clip
    /// edge enters or leaves it and AppKit asks the view under the pointer. The hover area takes no
    /// cursor updates: over its whole visible rect it would keep the resize cursor over a docked pane.
    @Test func aDividersCursorAreaStopsAtItsClip() throws {
        let harness = try DividerDragTests.Harness()
        defer { harness.close() }
        let handle = try harness.handle
        handle.updateTrackingAreas()
        let cursorAreas = { handle.trackingAreas.filter { $0.options.contains(.cursorUpdate) } }
        #expect(cursorAreas().count == 1, "one cursor area")
        let area = try #require(handle.cursorArea)
        #expect(cursorAreas().first === area)
        #expect(!area.options.contains(.inVisibleRect), "the area is the clipped rect, not the visible rect")
        #expect(area.rect == handle.bounds, "no clip: the whole handle")

        // A clip over the handle's first quarter (from minY): the area stops there.
        let superview = try #require(handle.superview)
        let clipInHandle = CGRect(x: handle.bounds.minX, y: handle.bounds.minY, width: handle.bounds.width, height: handle.bounds.height / 4)
        handle.cursorClip = superview.convert(clipInHandle, from: handle)
        #expect(cursorAreas().count == 1, "the clip swapped the area")
        #expect(handle.cursorArea?.rect == handle.cursorRectInBounds)
        #expect(handle.cursorRectInBounds.height < handle.bounds.height)

        // The handle moves along its length under the same clip: the area follows where the clip falls.
        let clipped = handle.cursorRectInBounds
        handle.frame = handle.frame.offsetBy(dx: 0, dy: handle.bounds.height / 8)
        #expect(handle.cursorRectInBounds != clipped)
        #expect(handle.cursorArea?.rect == handle.cursorRectInBounds)

        handle.cursorClip = nil
        #expect(handle.cursorArea?.rect == handle.bounds)
        #expect(cursorAreas().count == 1)
    }

    /// A side-by-side split's divider shows the column resize cursor over its band, and none past its clip
    /// (a dock over it, DividerCursorUnderDockTests): the same rule its cursor rect had.
    @Test func aDividerShowsItsResizeCursorOnlyInsideItsClip() throws {
        let harness = try DividerDragTests.Harness()
        defer { harness.close() }
        let handle = try harness.handle
        let center = CGPoint(x: handle.bounds.midX, y: handle.bounds.midY)
        let cursor = try #require(handle.cursor(at: center), "the resize cursor over the handle's middle")
        let expected: NSCursor
        if #available(macOS 15, *) { expected = .columnResize } else { expected = .resizeLeftRight }
        #expect(cursor.hotSpot == expected.hotSpot && cursor.image.size == expected.image.size, "the column resize cursor")
        #expect(handle.cursor(at: CGPoint(x: handle.bounds.maxX + 4, y: center.y)) == nil, "none past the handle")

        // A clip over the handle's first quarter (from minY): its far end shows no resize cursor.
        let clipInHandle = CGRect(x: handle.bounds.minX, y: handle.bounds.minY, width: handle.bounds.width, height: handle.bounds.height / 4)
        handle.cursorClip = try #require(handle.superview).convert(clipInHandle, from: handle)
        #expect(handle.cursor(at: CGPoint(x: center.x, y: clipInHandle.midY)) != nil, "inside the clip")
        let outside = CGPoint(x: center.x, y: handle.bounds.maxY - 1)
        #expect(handle.cursor(at: outside) == nil, "past the clip")
        handle.cursorClip = nil
        #expect(handle.cursor(at: outside) != nil, "no clip: the whole handle")
    }

    /// A handle that becomes hovered under a still pointer (a spring landed there, a layout moved it
    /// under the pointer) gets no cursor update from AppKit: it sets its cursor itself.
    @Test func aDividerHoveredUnderAStillPointerShowsItsCursor() throws {
        let harness = try DividerDragTests.Harness()
        defer { harness.close() }
        let handle = try harness.handle
        handle.setHovered(false)
        NSCursor.arrow.set()
        handle.setHovered(true)
        #expect(NSCursor.current !== NSCursor.arrow, "the hover set the resize cursor")
        #expect(NSCursor.current.hotSpot == handle.resizeCursor.hotSpot)
    }

    /// The Chief's settings links show the pointing hand from a cursor area AppKit supports: NSTrackingArea.h
    /// does not support `.activeAlways` with `.cursorUpdate`, so the hover area (`.activeForHover`, which is
    /// `.activeAlways` in a no-activate launch) carries none.
    @Test func aChiefLinksCursorAreaIsNotActiveAlways() {
        let link = HomeChiefLinkButton(title: "Show Memory", target: NSView(), action: #selector(NSView.display as (NSView) -> () -> Void))
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        link.updateTrackingAreas()
        let cursorAreas = link.trackingAreas.filter { $0.options.contains(.cursorUpdate) }
        #expect(cursorAreas.contains { $0.options.contains(.activeInKeyWindow) }, "the pointing hand's area")
        #expect(!cursorAreas.contains { $0.options.contains(.activeAlways) })
        #expect(link.trackingAreas.contains { $0.options.contains(.mouseEnteredAndExited) && $0.options.contains(.activeForHover) },
                "hover still arrives in every window of the active app")
        #expect(!link.trackingAreas.contains { $0.options.contains(.mouseEnteredAndExited) && $0.options.contains(.cursorUpdate) })
    }

    /// Only a selectable label has a cursor area (its I-beam): most labels never select, and an area
    /// on each would cost AppKit's tracking pass for nothing.
    @Test func onlyASelectableLabelHasACursorArea() {
        let label = ChromeLabel(labelWithString: "text")
        label.isSelectable = false
        let cursorAreas = { label.trackingAreas.filter { $0.options.contains(.cursorUpdate) }.count }
        #expect(cursorAreas() == 0)
        label.isSelectable = true
        #expect(cursorAreas() == 1)
        label.isSelectable = true
        #expect(cursorAreas() == 1, "setting it again adds none")
        label.isSelectable = false
        #expect(cursorAreas() == 0)
    }
}
