import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// #32981: on a scrolled spaces row, a dot the strip does not draw (cut by the pinned "+", the bar's
/// edge or the leading inset) must not act: no click or hover by the sliver that shows, no shortcut
/// hint, no drag layer painted over the "+" or past the bar, and no drag that clamps to it.
/// Leo 2026-11-24: "... because we hid spaces by default (we also need to fix stupid bugs and
/// usability issues with spaces)".
@MainActor @Suite(.serialized, .closesItsWindows) struct ProfileBarHiddenDotTests {
    /// A bar with `count` spaces, `active` current, `width` wide, in a window.
    private func makeBar(count: Int, active: Int, width: CGFloat = 160) -> (ProfileBarView, NSWindow) {
        _ = NSApplication.shared
        let model = SidebarModel()
        model.profiles = (0..<count).map { SidebarProfile(id: ProfileKey("space\($0)"), name: "Space \($0)") }
        model.activeProfileID = model.profiles[active].id
        let view = ProfileBarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 28), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        window.contentView = view
        view.leadingInset = 8
        view.layoutSubtreeIfNeeded()
        view.refresh()
        return (view, window)
    }

    private func event(_ type: NSEvent.EventType, _ point: NSPoint, in view: ProfileBarView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Every drawn dot sits whole between the leading inset and the "+", at every scroll position.
    @Test(arguments: [0, 10, 20, 30, 39]) func everyDrawnDotSitsWholeInsideTheStrip(_ active: Int) {
        let (view, window) = makeBar(count: 40, active: active)
        defer { window.close() }
        #expect(view.strip.scrolled, "the fixture does not overflow")
        let rects = view.slotRects(), plus = rects[40]
        #expect(view.dotIsDrawn(at: active), "the current space \(active) is not drawn")
        for index in view.drawnDotIndices {
            #expect(rects[index].minX >= 8 - 0.5, "dot \(index) \(rects[index]) is drawn cut by the leading inset")
            #expect(rects[index].maxX <= plus.minX + 0.5, "dot \(index) \(rects[index]) is drawn under the + \(plus)")
        }
    }

    /// The visible sliver of a dot cut by the + or by the leading edge is not pressable: a click there switches
    /// to no space and a hover lights none.
    @Test func theSliverOfAHiddenDotIsNotPressable() throws {
        var slivers: [(active: Int, index: Int, point: NSPoint)] = []
        for active in 0..<40 {
            let (view, window) = makeBar(count: 40, active: active)
            defer { window.close() }
            let rects = view.slotRects(), plus = rects[40], drawn = Set(view.drawnDotIndices)
            for index in 0..<40 where !drawn.contains(index) {
                // The part of the slot that lies on the bar and off the +.
                let lo = max(rects[index].minX, view.bounds.minX), hi = min(rects[index].maxX, plus.minX)
                guard hi - lo > 1 else { continue }
                slivers.append((active, index, NSPoint(x: (lo + hi) / 2, y: view.bounds.midY)))
            }
        }
        try #require(!slivers.isEmpty, "no scroll position leaves a cut dot: the fixture does not reach the bug")
        for sliver in slivers {
            let (view, window) = makeBar(count: 40, active: sliver.active)
            defer { window.close() }
            var intents: [SidebarIntent] = []
            view.model.onIntent = { intents.append($0) }
            let hit = view.interactionIndex(at: sliver.point)
            #expect(hit != sliver.index, "active \(sliver.active): the sliver of hidden dot \(sliver.index) at \(sliver.point) is pressable")
            view.mouseMoved(with: event(.mouseMoved, sliver.point, in: view))
            #expect(view.hovered != sliver.index, "active \(sliver.active): hovering the sliver lit hidden dot \(sliver.index)")
            view.mouseDown(with: event(.leftMouseDown, sliver.point, in: view))
            view.mouseUp(with: event(.leftMouseUp, sliver.point, in: view))
            let target = view.model.profiles[sliver.index].id
            #expect(!intents.contains(.switchProfile(target)), "active \(sliver.active): a click on the sliver switched to hidden space \(sliver.index): \(intents)")
        }
    }

    /// A dot drag shows only the drawn dots, clips its layers to the strip (never over the + or past the bar),
    /// and clamps the dragged dot between the first and last drawn dots.
    @Test func aDotDragShowsAndReachesOnlyTheDrawnDots() throws {
        let (view, window) = makeBar(count: 40, active: 20)
        defer { window.close() }
        let rects = view.slotRects(), plus = rects[40], drawn = view.drawnDotIndices
        let first = try #require(drawn.first), last = try #require(drawn.last)
        let start = NSPoint(x: rects[20].midX, y: view.bounds.midY)
        view.mouseDown(with: event(.leftMouseDown, start, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: start.x + 6, y: start.y), in: view))
        view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: view.bounds.maxX + 200, y: start.y), in: view))
        let drag = try #require(view.dotDrag, "the press did not start a dot drag")
        let mask = try #require(drag.container.mask, "the drag layers are not clipped")
        #expect(mask.frame.maxX <= plus.minX + 0.5, "the drag layers \(mask.frame) may paint over the + \(plus)")
        #expect(mask.frame.minX >= 8 - 0.5, "the drag layers \(mask.frame) may paint into the leading inset")
        #expect(drag.dots[20].position.x <= rects[last].midX + 0.5, "the dragged dot \(drag.dots[20].position.x) passed the last drawn dot \(rects[last].midX)")
        for index in 0..<40 where !drawn.contains(index) && index != 20 {
            #expect(drag.dots[index].opacity == 0, "hidden dot \(index) shows a drag layer")
        }
        view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: -200, y: start.y), in: view))
        #expect(drag.dots[20].position.x >= rects[first].midX - 0.5, "the dragged dot \(drag.dots[20].position.x) passed the first drawn dot \(rects[first].midX)")
        view.mouseUp(with: event(.leftMouseUp, NSPoint(x: -200, y: start.y), in: view))
    }
}
