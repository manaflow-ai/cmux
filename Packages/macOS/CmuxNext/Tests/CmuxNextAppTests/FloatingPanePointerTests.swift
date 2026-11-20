import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// A pointer on a floating pane's card: the bar at the top moves the pane, each of the 4 edges and the 4 corners
/// resizes it. The opposite edge or corner stays in place, the frame stays inside the pane area and is not smaller
/// than the smallest floating pane.
@MainActor struct FloatingPanePointerTests {
    let pane: PaneID = "a", other: PaneID = "b"
    /// The pane area, and a card in it: the left edge at 0.1, the top at 0.125, 0.4 wide and 0.375 high.
    let area = CGSize(width: 1000, height: 800)
    let card = CGRect(x: 100, y: 100, width: 400, height: 300)
    let press = CGPoint(x: 300, y: 105)

    func frame(_ zone: FloatingPaneCardView.Zone, dx: CGFloat = 0, dy: CGFloat = 0) -> CGRect {
        let drag = FloatingPaneDrag(pane: pane, zone: zone, startPoint: press, startCard: card,
                                    frame: LayoutFloatingPane.fractions(of: card, in: area))
        return drag.frame(at: CGPoint(x: press.x + dx, y: press.y + dy), in: area)
    }

    func expectFrame(_ frame: CGRect, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, _ what: String,
                     sourceLocation: SourceLocation = #_sourceLocation) {
        let near = abs(frame.minX - x) < 1e-9 && abs(frame.minY - y) < 1e-9 && abs(frame.width - w) < 1e-9 && abs(frame.height - h) < 1e-9
        #expect(near, "\(what): \(frame)", sourceLocation: sourceLocation)
    }

    @Test func theBarMovesThePaneAndKeepsItsSize() {
        expectFrame(frame(.move), x: 0.1, y: 0.125, w: 0.4, h: 0.375, "no move")
        expectFrame(frame(.move, dx: 50, dy: 50), x: 0.15, y: 0.1875, w: 0.4, h: 0.375, "a move right and down")
        expectFrame(frame(.move, dx: 1700, dy: -605), x: 0.6, y: 0, w: 0.4, h: 0.375, "a move past the right and the top edge stops there")
        expectFrame(frame(.move, dx: -1700, dy: 2000), x: 0, y: 0.625, w: 0.4, h: 0.375, "a move past the left and the bottom edge stops there")
    }

    @Test func theLeftRimMovesTheLeftEdgeOnly() {
        expectFrame(frame(.left, dx: -50, dy: 80), x: 0.05, y: 0.125, w: 0.45, h: 0.375, "wider to the left")
        expectFrame(frame(.left, dx: -500), x: 0, y: 0.125, w: 0.5, h: 0.375, "the left edge stops at the area's edge")
        expectFrame(frame(.left, dx: 1000), x: 0.35, y: 0.125, w: 0.15, h: 0.375, "the right edge stays and the pane keeps the smallest width")
    }

    @Test func theRightRimMovesTheRightEdgeOnly() {
        expectFrame(frame(.right, dx: 100, dy: 80), x: 0.1, y: 0.125, w: 0.5, h: 0.375, "wider to the right")
        expectFrame(frame(.right, dx: 5000), x: 0.1, y: 0.125, w: 0.9, h: 0.375, "the right edge stops at the area's edge")
        expectFrame(frame(.right, dx: -5000), x: 0.1, y: 0.125, w: 0.15, h: 0.375, "the pane keeps the smallest width")
    }

    @Test func theBottomRimMovesTheBottomEdgeOnly() {
        expectFrame(frame(.bottom, dx: 80, dy: 100), x: 0.1, y: 0.125, w: 0.4, h: 0.5, "higher")
        expectFrame(frame(.bottom, dy: 5000), x: 0.1, y: 0.125, w: 0.4, h: 0.875, "the bottom edge stops at the area's edge")
        expectFrame(frame(.bottom, dy: -5000), x: 0.1, y: 0.125, w: 0.4, h: 0.15, "the pane keeps the smallest height")
    }

    @Test func aBottomCornerMovesTwoEdges() {
        expectFrame(frame(.bottomLeft, dx: -50, dy: 100), x: 0.05, y: 0.125, w: 0.45, h: 0.5, "the bottom left corner")
        expectFrame(frame(.bottomRight, dx: 100, dy: 100), x: 0.1, y: 0.125, w: 0.5, h: 0.5, "the bottom right corner")
        expectFrame(frame(.bottomLeft, dx: 1000, dy: -5000), x: 0.35, y: 0.125, w: 0.15, h: 0.15, "the smallest pane, its top right corner in place")
    }

    @Test func aFrameIsInsideTheAreaAndNotTooSmall() {
        expectFrame(LayoutFloatingPane.clamped(CGRect(x: 0.9, y: -0.2, width: 0.05, height: 3)), x: 0.85, y: 0, w: 0.15, h: 1, "too small and outside")
        #expect(LayoutFloatingPane.clamped(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)) == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        // An area with no size has no fractions: the whole area.
        #expect(LayoutFloatingPane.fractions(of: card, in: .zero) == CGRect(x: 0, y: 0, width: 1, height: 1))
        // The card is the pane with its bar and its rim; the two rules are inverse.
        let inner = LayoutFloatingPane.paneRect(inCard: card)
        #expect(inner == CGRect(x: 105, y: 114, width: 390, height: 281))
        #expect(LayoutFloatingPane.cardRect(aroundPane: inner) == card)
    }

    @Test func theTopRimMovesTheTopEdgeOnly() {
        expectFrame(frame(.top, dx: 80, dy: -50), x: 0.1, y: 0.0625, w: 0.4, h: 0.4375, "higher at the top")
        expectFrame(frame(.top, dy: -500), x: 0.1, y: 0, w: 0.4, h: 0.5, "the top edge stops at the area's edge")
        expectFrame(frame(.top, dy: 5000), x: 0.1, y: 0.35, w: 0.4, h: 0.15, "the bottom edge stays and the pane keeps the smallest height")
    }

    @Test func aTopCornerMovesTwoEdges() {
        expectFrame(frame(.topLeft, dx: -50, dy: -50), x: 0.05, y: 0.0625, w: 0.45, h: 0.4375, "the top left corner")
        expectFrame(frame(.topRight, dx: 100, dy: -50), x: 0.1, y: 0.0625, w: 0.5, h: 0.4375, "the top right corner")
        expectFrame(frame(.topRight, dx: -5000, dy: 5000), x: 0.1, y: 0.35, w: 0.15, h: 0.15, "the smallest pane, its bottom left corner in place")
        expectFrame(frame(.topLeft, dx: 5000, dy: 5000), x: 0.35, y: 0.35, w: 0.15, h: 0.15, "the smallest pane, its bottom right corner in place")
    }

    @Test func theCardKnowsWhichPartAPointIsOn() {
        let view = FloatingPaneCardView(pane: pane)
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        #expect(view.zone(at: CGPoint(x: 100, y: 5)) == .move, "the bar below the top band moves the pane")
        #expect(view.zone(at: CGPoint(x: 100, y: 13)) == .move)
        #expect(view.zone(at: CGPoint(x: 100, y: 2)) == .top, "the top band is the top of the bar")
        #expect(view.zone(at: CGPoint(x: 2, y: 2)) == .topLeft)
        #expect(view.zone(at: CGPoint(x: 198, y: 2)) == .topRight)
        #expect(view.zone(at: CGPoint(x: 10, y: 2)) == .topLeft, "the top band near the side is the corner")
        #expect(view.zone(at: CGPoint(x: 2, y: 10)) == .topLeft, "the side rim near the top is the corner")
        #expect(view.zone(at: CGPoint(x: 198, y: 10)) == .topRight)
        #expect(view.zone(at: CGPoint(x: 2, y: 60)) == .left)
        #expect(view.zone(at: CGPoint(x: 198, y: 60)) == .right)
        #expect(view.zone(at: CGPoint(x: 100, y: 148)) == .bottom)
        #expect(view.zone(at: CGPoint(x: 5, y: 148)) == .bottomLeft)
        #expect(view.zone(at: CGPoint(x: 195, y: 148)) == .bottomRight)
        #expect(view.zone(at: CGPoint(x: 2, y: 140)) == .bottomLeft, "the side rim near the bottom is the corner")
        #expect(view.zone(at: CGPoint(x: 198, y: 140)) == .bottomRight)
    }

    /// The cursor's rectangles: no two on the same point, and each one in the zone that a press there gets.
    /// Together they are the card with its band, less the pane.
    func expectCursorRects(of view: FloatingPaneCardView, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let entries = view.cursorRects
        #expect(Set(entries.map(\.zone)) == Set(FloatingPaneCardView.Zone.allCases), "\(what)", sourceLocation: sourceLocation)
        for (index, entry) in entries.enumerated() {
            #expect(view.part(at: CGPoint(x: entry.rect.midX, y: entry.rect.midY)) == entry.zone, "\(what): \(entry.zone) \(entry.rect)",
                    sourceLocation: sourceLocation)
            for other in entries[(index + 1)...] {
                #expect(!entry.rect.intersects(other.rect), "\(what): \(entry.zone) \(entry.rect) and \(other.zone) \(other.rect)",
                        sourceLocation: sourceLocation)
            }
        }
        let inner = LayoutFloatingPane.paneRect(inCard: view.cardBounds)
        let area = entries.reduce(0) { $0 + $1.rect.width * $1.rect.height }
        #expect(area == view.bounds.width * view.bounds.height - inner.width * inner.height, "\(what)", sourceLocation: sourceLocation)
    }

    @Test func eachPartOfTheBarAndTheRimHasOneCursorRectangle() {
        let view = FloatingPaneCardView(pane: pane)
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        expectCursorRects(of: view, "a card with no band outside")
    }

    /// With the band outside the card the rectangles reach as far as a press does, and they follow the 2 knobs'
    /// values at the next placement.
    @Test func theCursorRectanglesFollowTheBandAndTheCornerZone() {
        let view = FloatingPaneCardView(pane: pane)
        let area = CGRect(origin: .zero, size: self.area)
        view.place(card, reach: FloatingPaneReach(), in: area)
        #expect(view.frame == card.insetBy(dx: -8, dy: -8), "the defaults: 8 points outside each edge")
        #expect(view.cardFrame == card && view.cardBounds == CGRect(x: 8, y: 8, width: 400, height: 300))
        expectCursorRects(of: view, "the defaults")
        /// All the rectangles of `zone` as one, in the pane area's coordinates.
        func zones(_ zone: FloatingPaneCardView.Zone) -> CGRect {
            view.cursorRects.filter { $0.zone == zone }.reduce(CGRect.null) { $0.union($1.rect.offsetBy(dx: view.frame.minX, dy: view.frame.minY)) }
        }
        #expect(zones(.left) == CGRect(x: 92, y: 112, width: 13, height: 276), "13 points on the left: \(zones(.left))")
        #expect(zones(.top) == CGRect(x: 112, y: 92, width: 376, height: 12), "12 points at the top: \(zones(.top))")
        #expect(zones(.topLeft) == CGRect(x: 92, y: 92, width: 20, height: 20), "20 points by 20 points: \(zones(.topLeft))")
        #expect(zones(.bottomRight) == CGRect(x: 488, y: 388, width: 20, height: 20), "\(zones(.bottomRight))")

        #expect(view.place(card, reach: FloatingPaneReach(band: 24, corner: 40), in: area), "a new band moves the view")
        #expect(view.frame == card.insetBy(dx: -20, dy: -20) && view.cardFrame == card)
        expectCursorRects(of: view, "a band of 24 and a corner zone of 40")
        #expect(zones(.left) == CGRect(x: 80, y: 120, width: 25, height: 260), "\(zones(.left))")
        #expect(zones(.top) == CGRect(x: 120, y: 80, width: 360, height: 24), "\(zones(.top))")
        #expect(zones(.topLeft) == CGRect(x: 80, y: 80, width: 40, height: 40), "\(zones(.topLeft))")

        // At the area's edge the band outside is the room that is there.
        let corner = CGRect(x: 0, y: 3, width: 400, height: 300)
        view.place(corner, reach: FloatingPaneReach(), in: area)
        #expect(view.frame == CGRect(x: 0, y: 0, width: 408, height: 311) && view.cardFrame == corner)
        expectCursorRects(of: view, "at the area's edge")
        #expect(zones(.left) == CGRect(x: 0, y: 15, width: 5, height: 276), "the rim only: \(zones(.left))")
        #expect(zones(.top) == CGRect(x: 12, y: 0, width: 376, height: 7), "3 points of room and the top 4 of the bar: \(zones(.top))")
        #expect(!view.place(corner, reach: FloatingPaneReach(), in: area), "the same placement does no work")
    }

    /// A card in front hides the cursor rectangles under it: AppKit does not.
    @Test func noCursorRectangleShowsUnderACardInFront() {
        let view = FloatingPaneCardView(pane: pane)
        let area = CGRect(origin: .zero, size: self.area)
        let front = CGRect(x: 450, y: 250, width: 300, height: 300)
        view.place(card, reach: FloatingPaneReach(), in: area, under: [front])
        let rects = view.cursorRects.map { $0.rect.offsetBy(dx: view.frame.minX, dy: view.frame.minY) }
        #expect(!rects.isEmpty)
        for rect in rects {
            #expect(!rect.intersects(front), "\(rect) lies under the card in front")
        }
        let shown = rects.reduce(0) { $0 + $1.width * $1.height }
        let inner = LayoutFloatingPane.paneRect(inCard: card)
        let hidden = view.frame.intersection(front), hiddenInner = inner.intersection(front)
        let all = view.frame.width * view.frame.height - inner.width * inner.height
        #expect(shown == all - (hidden.width * hidden.height - hiddenInner.width * hiddenInner.height), "the rest shows: \(shown)")
    }

    /// The 2 knobs of a pointer's reach: their defaults, their ranges and their place in the look.
    @Test func theResizeBandAndTheCornerZoneAreKnobs() {
        #expect(FloatingPaneTunables.defaultResizeBand == 12 && FloatingPaneTunables.defaultCornerZone == 20)
        let keys = FloatingPaneTunables.all.map(\.key)
        #expect(keys.contains("floatingPane.resizeBand") && keys.contains("floatingPane.cornerZone"), "\(keys)")
        #expect(FloatingPaneLook().resizeBand == 12 && FloatingPaneLook().cornerZone == 20)
        let reach = FloatingPaneReach()
        #expect(reach.band == 12 && reach.corner == 20 && reach.outside == 8 && reach.cornerInside == 12)
        #expect(FloatingPaneReach(band: 4, corner: 10).outside == 0, "the smallest band is inside the card only")
        #expect(FloatingPaneReach(band: 24, corner: 10).cornerInside == 5, "a corner zone does not end before the rim's inner edge")
    }

    /// The bar shows a hand, and each resize zone shows a cursor of its own that is not the hand.
    @Test func aResizeZoneDoesNotShowTheHand() {
        #expect(FloatingPaneCardView.cursor(for: .move) === NSCursor.openHand)
        #expect(FloatingPaneCardView.cursor(for: .move, dragging: true) === NSCursor.closedHand)
        for zone in FloatingPaneCardView.Zone.allCases where zone != .move {
            let cursor = FloatingPaneCardView.cursor(for: zone, dragging: true)
            #expect(cursor !== NSCursor.openHand && cursor !== NSCursor.closedHand && cursor !== NSCursor.arrow, "\(zone)")
        }
    }

    /// The view shows a drag's frame until the release, and tells a new frame or a new order from a new set of panes.
    @Test func theViewStateShowsADragAndTellsWhatChanged() {
        let first = LayoutFloatingPane(pane: pane, frame: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4))
        let second = LayoutFloatingPane(pane: other, frame: CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3))
        var state = FloatingPanesState()
        #expect(state.takeChange() == FloatingPanesState.Change.none)
        state.list = [first, second]
        #expect(state.takeChange() == .panes)
        #expect(state.takeChange() == FloatingPanesState.Change.none)
        state.list[0].frame.origin.x = 0.2
        #expect(state.takeChange() == .frames)
        state.list = [state.list[1], state.list[0]]
        #expect(state.takeChange() == .frames, "a new order of the same panes is no new set of panes")

        let dragged = CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3)
        state.drag = FloatingPaneDrag(pane: other, zone: .move, startPoint: .zero, startCard: .zero, frame: dragged)
        #expect(state.shown.map(\.pane) == [other, pane])
        #expect(state.shown[0].frame == dragged)
        #expect(state.shown[1] == state.list[1])
        state.drag = nil
        #expect(state.shown == state.list)
    }
}
