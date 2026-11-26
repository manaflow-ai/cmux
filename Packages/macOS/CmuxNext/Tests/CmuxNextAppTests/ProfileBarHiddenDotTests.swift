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
        let (view, window) = makeBar(count: 40, active: 0)
        defer { window.close() }
        var slivers: [(active: Int, index: Int, point: NSPoint)] = []
        for active in view.model.profiles.indices {
            view.model.activeProfileID = view.model.profiles[active].id
            view.refresh()
            let rects = view.slotRects(), plus = rects[40], drawn = Set(view.drawnDotIndices)
            for index in 0..<40 where !drawn.contains(index) {
                // The part of the slot that lies on the bar and off the +.
                let lo = max(rects[index].minX, view.bounds.minX), hi = min(rects[index].maxX, plus.minX)
                guard hi - lo > 1 else { continue }
                slivers.append((active, index, NSPoint(x: (lo + hi) / 2, y: view.bounds.midY)))
            }
        }
        try #require(!slivers.isEmpty, "no scroll position leaves a cut dot: the fixture does not reach the bug")
        var intents: [SidebarIntent] = []
        view.model.onIntent = { intents.append($0) }
        for sliver in slivers {
            view.model.activeProfileID = view.model.profiles[sliver.active].id
            view.refresh()
            intents.removeAll()
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
        let dragged = try #require(drag.dots[20])
        #expect(dragged.position.x <= rects[last].midX + 0.5, "the dragged dot \(dragged.position.x) passed the last drawn dot \(rects[last].midX)")
        #expect(Set(drag.dots.keys) == Set(drawn), "the drag allocates layers only for drawn dots")
        #expect(drag.container.sublayers?.count == drawn.count, "the drag created an offscreen layer")
        view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: -200, y: start.y), in: view))
        #expect(dragged.position.x >= rects[first].midX - 0.5, "the dragged dot \(dragged.position.x) passed the first drawn dot \(rects[first].midX)")
        view.mouseUp(with: event(.leftMouseUp, NSPoint(x: -200, y: start.y), in: view))
    }

    @Test func hoveredSpaceScrolledOutByAKeyboardSwitchLosesItsHighlight() {
        let (view, window) = makeBar(count: 40, active: 0)
        defer { window.close() }
        view.setHovered(0)
        #expect(view.hoverChip != nil)
        view.model.activeProfileID = view.model.profiles[39].id
        view.refresh()
        #expect(view.hoverChip == nil)
    }

    @Test func replacingAPressedSpaceBeforeDraggingDoesNotActivateItsReplacement() {
        let (view, window) = makeBar(count: 3, active: 1)
        defer { window.close() }
        let slot = view.slotRects()[1]
        let point = NSPoint(x: slot.midX, y: slot.midY)
        view.mouseDown(with: event(.leftMouseDown, point, in: view))
        view.model.profiles.swapAt(1, 2)
        var intents: [SidebarIntent] = []
        view.model.onIntent = { intents.append($0) }
        view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: point.x + 12, y: point.y), in: view))
        #expect(view.dotDrag == nil)
        view.mouseUp(with: event(.leftMouseUp, point, in: view))
        #expect(intents.isEmpty)
    }

    @Test(arguments: [true, false]) func changingSpaceOrderDuringDragCancelsTheDrop(removing: Bool) throws {
        let (view, window) = makeBar(count: 3, active: 2)
        defer { window.close() }
        let slot = view.slotRects()[2]
        let start = NSPoint(x: slot.midX, y: slot.midY)
        let outside = NSPoint(x: view.bounds.maxX + 20, y: start.y)
        view.mouseDown(with: event(.leftMouseDown, start, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, outside, in: view))
        try #require(view.dotDrag?.outsideWindow == true)
        var intents: [SidebarIntent] = []
        view.model.onIntent = { intents.append($0) }
        if removing { view.model.profiles.removeLast() } else { view.model.profiles.swapAt(0, 2) }
        view.mouseUp(with: event(.leftMouseUp, outside, in: view))
        #expect(view.dotDrag == nil)
        #expect(intents.isEmpty)
    }

    /// Shortcut hints (Ctrl-1…9) go only on drawn dots, each with the digit that selects it (9: the last space).
    @Test func spaceShortcutHintsShowOnlyOnDrawnDots() throws {
        let design = DesignSettings.shared
        let saved = (design.sidebarSections.showSpaces, design.sidebarSections.noFade)
        defer { (design.sidebarSections.showSpaces, design.sidebarSections.noFade) = saved }
        design.sidebarSections.showSpaces = true
        design.sidebarSections.noFade = false
        let h = SidebarTrailingColumnTests.KindHarness(width: 220)
        defer { h.window.close() }
        h.sidebar.spacesVisibility = .always
        h.sidebar.spacesPosition = .bottom
        h.model.profiles = (0..<40).map { SidebarProfile(id: ProfileKey("hint-space-\($0)"), name: "Space \($0)") }
        h.model.activeProfileID = h.model.profiles[20].id
        h.sidebar.renderNow()
        h.sidebar.layoutSubtreeIfNeeded()
        let bar = h.sidebar.profileBar
        try #require(!bar.isHidden && bar.strip.scrolled, "the fixture shows no scrolled strip")
        let hints = h.sidebar.shortcutHintSpaceFrames
        let rects = bar.slotRects(), drawn = bar.drawnDotIndices
        // Ctrl-1…8 reach the first eight spaces and Ctrl-9 the last: a chip only where its digit lands and the dot is drawn.
        let expected = drawn.compactMap { $0 < 8 ? ($0 + 1, $0) : $0 == 39 ? (9, 39) : nil }
        #expect(hints.map(\.digit) == expected.map(\.0), "hints \(hints.map(\.digit)) for drawn dots \(drawn)")
        for (hint, (_, index)) in zip(hints, expected) {
            #expect(hint.rect == bar.convert(rects[index], to: h.sidebar), "the ⌃\(hint.digit) chip is not on space \(index)'s dot")
        }
        // The ninth space is not the last: Ctrl-9 does not select it, so no chip says it does.
        h.model.activeProfileID = h.model.profiles[8].id
        h.sidebar.renderNow()
        h.sidebar.layoutSubtreeIfNeeded()
        #expect(!h.sidebar.shortcutHintSpaceFrames.contains { $0.digit == 9 })
        h.model.activeProfileID = h.model.profiles[39].id
        h.sidebar.renderNow()
        h.sidebar.layoutSubtreeIfNeeded()
        let last = try #require(h.sidebar.shortcutHintSpaceFrames.first { $0.digit == 9 })
        #expect(last.rect == bar.convert(bar.slotRects()[39], to: h.sidebar))
    }
}
