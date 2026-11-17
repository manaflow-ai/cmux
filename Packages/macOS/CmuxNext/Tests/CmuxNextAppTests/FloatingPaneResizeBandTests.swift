import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// The resize band of a floating pane: 8 points outside the card's edge and the rim inside it (the top 4 points of
/// the bar at the top), with a corner zone of 20 points by 20 points from the band's outer corner. A press in the
/// band is the card's, also over a tiled pane; a press 1 point past the band is not. At an edge of the pane area
/// with no room outside, the band is the room and the rim. The content keeps each press on it, also on a scroll bar
/// at its edge.
@MainActor @Suite(.closesItsWindows) struct FloatingPaneResizeBandTests {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// A card and its pane's host in a pane area of 1000 by 800, above a tiled pane. The tiled pane and the
    /// floating pane's content each have a scroll bar at their right edge.
    @MainActor final class Card {
        static let pane: PaneID = "float"
        static let scrollBarWidth: CGFloat = 12
        let window: NSWindow
        let area: NSView = FlippedView()
        let tiled = NSView(), tiledScrollBar = NSView()
        let content = NSView(), contentScrollBar = NSView()
        let card = FloatingPaneCardView(pane: Card.pane)
        let host: PaneHostView
        var state = FloatingPanesState()

        init(tiled tiledFrame: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 800)) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
            window.contentView = root
            area.frame = root.bounds
            root.addSubview(area)
            tiled.frame = tiledFrame
            tiledScrollBar.frame = CGRect(x: tiledFrame.width - Self.scrollBarWidth, y: 0, width: Self.scrollBarWidth, height: tiledFrame.height)
            tiled.addSubview(tiledScrollBar)
            area.addSubview(tiled)
            area.addSubview(card)
            content.addSubview(contentScrollBar)
            host = PaneHostView(pane: Self.pane, content: content)
            area.addSubview(host)
            state.cards[Self.pane] = card
        }

        /// Puts the pane's host inside `card` and the card around it, as the screen's view does.
        func place(_ card: CGRect) {
            host.frame = LayoutFloatingPane.paneRect(inCard: card)
            _ = state.present(in: area, hosts: [Self.pane: host], padding: 0, wholeCard: false)
            contentScrollBar.frame = CGRect(x: content.bounds.maxX - Self.scrollBarWidth, y: 0, width: Self.scrollBarWidth, height: content.bounds.height)
        }

        /// The view that a press at `point` (the pane area's coordinates) goes to.
        func hit(at point: CGPoint) -> NSView? {
            guard let above = area.superview else { return nil }
            return area.hitTest(above.convert(point, from: area))
        }

        /// What a press at `point` is on: a zone of the card, the floating pane's content or its scroll bar, or the
        /// tiled pane below or its scroll bar.
        func part(at point: CGPoint) -> String {
            guard let hit = hit(at: point) else { return "nothing" }
            if hit === card { return "\(card.zone(at: card.convert(point, from: area)))" }
            if hit === contentScrollBar { return "content scroll bar" }
            if hit.isDescendant(of: host) { return "content" }
            if hit === tiledScrollBar { return "tiled scroll bar" }
            return hit === tiled ? "tiled" : "other"
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: area.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
    }

    typealias Check = (point: CGPoint, part: String, what: String)

    /// Each zone's outer limit and inner limit, and the point 1 point past each, for a card at `card`. `left` and
    /// `top` are the room outside the card on those 2 sides (the other 2 sides have 8 points or more). `pastRight`
    /// is what lies past the band on the right.
    func checks(_ card: CGRect, left: CGFloat = 8, top: CGFloat = 8, pastRight: String = "tiled") -> [Check] {
        let (minX, minY, maxX, maxY, midX, midY) = (card.minX, card.minY, card.maxX, card.maxY, card.midX, card.midY)
        func at(_ x: CGFloat, _ y: CGFloat, _ part: String, _ what: String) -> Check { (CGPoint(x: x, y: y), part, what) }
        var list: [Check] = [
            at(minX - left + 0.5, midY, "left", "the left band's outer limit"),
            at(minX + 4.5, midY, "left", "the left band's inner limit: the rim"),
            at(minX + 5.5, midY, "content", "past the left rim"),
            at(maxX + 7.5, midY, "right", "the right band's outer limit"),
            at(maxX + 8.5, midY, pastRight, "past the right band"),
            at(maxX - 4.5, midY, "right", "the right band's inner limit: the rim"),
            at(maxX - 5.5, midY, "content scroll bar", "past the right rim: the content's scroll bar keeps its press"),
            at(midX, maxY + 7.5, "bottom", "the bottom band's outer limit"),
            at(midX, maxY + 8.5, "tiled", "past the bottom band"),
            at(midX, maxY - 4.5, "bottom", "the bottom band's inner limit: the rim"),
            at(midX, maxY - 5.5, "content", "past the bottom rim"),
            at(midX, minY - top + 0.5, "top", "the top band's outer limit"),
            at(midX, minY + 3.5, "top", "the top band's inner limit: the top 4 points of the bar"),
            at(midX, minY + 4.5, "move", "the bar below the top band moves the pane"),
            at(midX, minY + 13.5, "move", "the bar's lower limit"),
            at(midX, minY + 14.5, "content", "below the bar"),
            at(minX - left + 0.5, minY - top + 0.5, "topLeft", "the top left zone's outer corner"),
            at(minX + 11.5, minY + 2, "topLeft", "the top left zone's limit along the top"),
            at(minX + 12.5, minY + 2, "top", "past the top left zone along the top"),
            at(minX + 2, minY + 11.5, "topLeft", "the top left zone's limit along the left side"),
            at(minX + 2, minY + 12.5, "left", "past the top left zone along the left side"),
            at(minX + 8, minY + 8, "topLeft", "the top left zone is a square, also in the bar"),
            at(maxX + 7.5, minY - top + 0.5, "topRight", "the top right zone's outer corner"),
            at(maxX + 8.5, minY + 0.5, pastRight, "past the top right zone"),
            at(maxX - 11.5, minY + 2, "topRight", "the top right zone's limit along the top"),
            at(maxX - 12.5, minY + 2, "top", "past the top right zone along the top"),
            at(maxX - 2, minY + 11.5, "topRight", "the top right zone's limit along the right side"),
            at(maxX - 2, minY + 12.5, "right", "past the top right zone along the right side"),
            at(maxX - 8, minY + 8, "topRight", "the top right zone is a square, also in the bar"),
            at(minX - left + 0.5, maxY + 7.5, "bottomLeft", "the bottom left zone's outer corner"),
            at(minX + 0.5, maxY + 8.5, "tiled", "past the bottom left zone"),
            at(minX + 11.5, maxY - 2, "bottomLeft", "the bottom left zone's limit along the bottom"),
            at(minX + 12.5, maxY - 2, "bottom", "past the bottom left zone along the bottom"),
            at(minX + 2, maxY - 11.5, "bottomLeft", "the bottom left zone's limit along the left side"),
            at(minX + 2, maxY - 12.5, "left", "past the bottom left zone along the left side"),
            at(maxX + 7.5, maxY + 7.5, "bottomRight", "the bottom right zone's outer corner"),
            at(maxX + 8.5, maxY + 8.5, pastRight, "past the bottom right zone's outer corner"),
            at(maxX - 11.5, maxY - 2, "bottomRight", "the bottom right zone's limit along the bottom"),
            at(maxX - 12.5, maxY - 2, "bottom", "past the bottom right zone along the bottom"),
            at(maxX - 2, maxY - 11.5, "bottomRight", "the bottom right zone's limit along the right side"),
            at(maxX - 2, maxY - 12.5, "right", "past the bottom right zone along the right side"),
            at(maxX + 4, maxY - 11.5, "bottomRight", "the bottom right zone's limit outside the right side"),
            at(maxX + 4, maxY - 12.5, "right", "past the bottom right zone outside the right side"),
            at(maxX - 11.5, maxY + 4, "bottomRight", "the bottom right zone's limit outside the bottom"),
            at(maxX - 12.5, maxY + 4, "bottom", "past the bottom right zone outside the bottom"),
        ]
        if left > 0 {
            list.append(at(minX - left - 0.5, midY, "tiled", "past the left band"))
            list.append(at(minX - left - 0.5, maxY + 8.5, "tiled", "past the bottom left zone's outer corner"))
            list.append(at(minX - left / 2, maxY - 11.5, "bottomLeft", "the bottom left zone's limit outside the left side"))
            list.append(at(minX - left / 2, maxY - 12.5, "left", "past the bottom left zone outside the left side"))
        }
        if top > 0 {
            list.append(at(midX, minY - top - 0.5, "tiled", "past the top band"))
            list.append(at(maxX + 8.5, minY - top - 0.5, pastRight, "past the top right zone's outer corner"))
            list.append(at(maxX - 11.5, minY - top / 2, "topRight", "the top right zone's limit outside the top"))
            list.append(at(maxX - 12.5, minY - top / 2, "top", "past the top right zone outside the top"))
        }
        if left > 0, top > 0 {
            list.append(at(minX - left - 0.5, minY - top - 0.5, "tiled", "past the top left zone's outer corner"))
        }
        return list
    }

    func expect(_ fixture: Card, _ checks: [Check], _ place: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for check in checks {
            let part = fixture.part(at: check.point)
            #expect(part == check.part, "\(place): \(check.what), at \(check.point): \(part), not \(check.part)", sourceLocation: sourceLocation)
        }
    }

    let middle = CGRect(x: 300, y: 200, width: 400, height: 300)

    @Test func aCardInTheMiddleHasItsBandOutsideAndOnItsRim() {
        let fixture = Card()
        defer { fixture.window.closeAfterTest() }
        fixture.place(middle)
        expect(fixture, checks(middle), "the middle")
    }

    /// No room outside on the left and at the top: the band there is the rim (the top 4 points of the bar at the
    /// top). The 2 other sides keep their 8 points outside.
    @Test func aCardAtTheAreasEdgeHasItsBandInsideThere() {
        let fixture = Card()
        defer { fixture.window.closeAfterTest() }
        let corner = CGRect(x: 0, y: 0, width: 400, height: 300)
        fixture.place(corner)
        expect(fixture, checks(corner, left: 0, top: 0), "the area's top left corner")
        // 3 points of room: the band is those 3 points and the rim.
        let near = CGRect(x: 3, y: 3, width: 400, height: 300)
        fixture.place(near)
        expect(fixture, checks(near, left: 3, top: 3).filter { $0.part != "tiled" }, "3 points from the area's top left corner")
    }

    /// The card's right edge lies on the scroll bar of the tiled pane below: the band's 8 points are the card's,
    /// the rest of that scroll bar keeps its press, and so does the scroll bar of the floating pane's content.
    @Test func aCardOverATiledPanesScrollBarLeavesTheRestOfItAlone() {
        let fixture = Card(tiled: CGRect(x: 0, y: 0, width: 712, height: 800))
        defer { fixture.window.closeAfterTest() }
        fixture.place(middle)
        expect(fixture, checks(middle, pastRight: "tiled scroll bar"), "over a tiled pane's scroll bar")
        #expect(fixture.part(at: CGPoint(x: 705, y: 100)) == "tiled scroll bar", "above the card the tiled pane's scroll bar has each press")
    }

    @Test func theBandFollowsAMoveOfTheCard() {
        let fixture = Card()
        defer { fixture.window.closeAfterTest() }
        fixture.place(middle)
        let moved = middle.offsetBy(dx: 120, dy: 90)
        fixture.place(moved)
        expect(fixture, checks(moved), "after a move")
        #expect(fixture.part(at: CGPoint(x: middle.minX - 7.5, y: middle.minY + 20)) == "tiled", "the old place has no band")
        let larger = CGRect(x: 200, y: 150, width: 560, height: 420)
        fixture.place(larger)
        expect(fixture, checks(larger), "after a resize")
    }

    /// A press in the band outside the card starts the resize of that side, and after the release the band is
    /// where it was and the window's cursor rectangles are on again.
    @Test func aPressInTheBandOutsideTheCardStartsTheResize() throws {
        let fixture = Card()
        defer { fixture.window.closeAfterTest() }
        fixture.place(middle)
        var began: [FloatingPaneCardView.Zone] = [], ended = 0
        fixture.card.onDrag = { phase, _ in
            switch phase {
            case let .began(zone): began.append(zone)
            case .moved: break
            case .ended: ended += 1
            }
        }
        let presses: [(CGPoint, FloatingPaneCardView.Zone)] = [
            (CGPoint(x: middle.minX - 6, y: middle.midY), .left), (CGPoint(x: middle.maxX + 6, y: middle.midY), .right),
            (CGPoint(x: middle.midX, y: middle.minY - 6), .top), (CGPoint(x: middle.midX, y: middle.maxY + 6), .bottom),
            (CGPoint(x: middle.minX - 6, y: middle.minY - 6), .topLeft), (CGPoint(x: middle.maxX + 6, y: middle.maxY + 6), .bottomRight),
        ]
        for (point, zone) in presses {
            began = []
            let target = fixture.hit(at: point)
            #expect(target === fixture.card, "a press at \(point) is the card's")
            guard target === fixture.card else { continue }
            try fixture.card.mouseDown(with: fixture.event(.leftMouseDown, at: point))
            try fixture.card.mouseDragged(with: fixture.event(.leftMouseDragged, at: CGPoint(x: point.x + 20, y: point.y + 20)))
            try fixture.card.mouseUp(with: fixture.event(.leftMouseUp, at: CGPoint(x: point.x + 20, y: point.y + 20)))
            #expect(began == [zone], "a press at \(point) starts the resize of \(zone): \(began)")
            #expect(fixture.window.areCursorRectsEnabled, "the cursor rectangles are on again after the release")
        }
        #expect(ended == presses.count, "each press ends with its release: \(ended)")
        expect(fixture, checks(middle), "after a drag")
    }

    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// Two columns, the second split top and bottom, and a floating pane that lies over a part of that split's
    /// divider.
    @MainActor final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init() {
            let layout = ScreenLayout.columns([
                LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
                LayoutColumn(id: "c2", width: 0.5, root: .split("x", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))),
            ])
            let floating = [LayoutFloatingPane(pane: "f", frame: CGRect(x: 0.6, y: 0.3, width: 0.25, height: 0.4))]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout, floating: floating)],
                                activeScreenID: "s", focusedPane: "p1")
            model.followsDesignMetrics = false
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = true
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            for _ in 0..<600 where root.advanceFrame(1.0 / 120) {}
        }

        var screen: ScreenContentView { root.screenViews["s"]! }
    }

    /// A divider under a floating pane's card or under its band shows no hover: a press there is the floating
    /// pane's.
    @Test func aDividerUnderAFloatingPaneOrItsBandIsNotHovered() throws {
        let fixture = Screen()
        defer { fixture.window.closeAfterTest() }
        let screen = fixture.screen
        let handle = try #require(screen.dividerViews[.split("x")])
        let card = try #require(screen.geometry.floatingCards["f"])
        let line = screen.convert(handle.cursorRectInBounds, from: handle)
        try #require(line.minX < card.minX - 40 && line.maxX > card.maxX + 40 && line.midY > card.minY + 40 && line.midY < card.maxY - 40,
                     "the divider runs on under the floating pane and shows on its 2 sides: \(line), card \(card)")
        // The pointer's place, in a box: the closure reads the place that the test gives it after the closure was made.
        @MainActor final class Pointer { var place = CGPoint.zero }
        let pointer = Pointer()
        pointer.place = CGPoint(x: card.maxX + 30, y: line.midY)
        fixture.root.context.hoverPointer = { _ in screen.convert(pointer.place, to: nil) }
        fixture.root.context.hoverReachesWindow = { _ in true }

        screen.refreshDividerHover()
        #expect(handle.isHovered, "beside the floating pane the divider hovers")

        pointer.place = CGPoint(x: card.midX, y: line.midY)
        screen.refreshDividerHover()
        #expect(!handle.isHovered, "the pointer over the floating pane hovers no divider under it")

        pointer.place = CGPoint(x: card.maxX + 4, y: line.midY)
        screen.refreshDividerHover()
        #expect(!handle.isHovered, "the pointer over the floating pane's band hovers no divider under it")
    }

    /// In the screen's view the band lies over a tiled pane: a press in it is the card's, 1 point past it the
    /// tiled pane has the press, and a drag from the band moves that edge of the floating pane.
    @Test func aDragFromTheBandOverATiledPaneResizesTheFloatingPane() throws {
        let fixture = Screen()
        defer { fixture.window.closeAfterTest() }
        let screen = fixture.screen
        let rect = try #require(screen.geometry.floatingCards["f"])
        let card = try #require(screen.floatState.cards["f"])
        let tiled = try #require(fixture.root.context.hosts["p2"])
        let above = try #require(screen.superview)
        func hit(_ point: CGPoint) -> NSView? { screen.hitTest(above.convert(point, from: screen)) }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: screen.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let press = CGPoint(x: rect.minX - 7.5, y: rect.minY + 60), past = CGPoint(x: rect.minX - 8.5, y: rect.minY + 60)
        try #require(tiled.frame.contains(press) && tiled.frame.contains(past), "the 2 points are over the tiled pane: \(tiled.frame)")
        #expect(hit(past)?.isDescendant(of: tiled) == true, "1 point past the band the tiled pane has the press")
        try #require(hit(press) === card, "a press in the band over the tiled pane is the card's")

        let before = try #require(fixture.model.screens.first?.floating.first?.frame)
        try card.mouseDown(with: event(.leftMouseDown, press))
        try card.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: press.x - 60, y: press.y)))
        try card.mouseUp(with: event(.leftMouseUp, CGPoint(x: press.x - 60, y: press.y)))
        let after = try #require(fixture.model.screens.first?.floating.first?.frame)
        #expect(after.minX < before.minX - 0.03, "the left edge moved with the pointer: \(before) to \(after)")
        #expect(abs(after.maxX - before.maxX) < 0.001 && abs(after.minY - before.minY) < 0.001 && abs(after.height - before.height) < 0.001,
                "the 3 other edges stay: \(before) to \(after)")
        #expect(fixture.window.areCursorRectsEnabled)
    }
}
