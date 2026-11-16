import AppKit
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

    /// The cursor's rectangles: one for each part of the bar and the rim, no two on the same point, and each one
    /// in the zone that a press there gets. Together they are the card less the pane.
    @Test func eachPartOfTheBarAndTheRimHasOneCursorRectangle() {
        let view = FloatingPaneCardView(pane: pane)
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        let entries = FloatingPaneCardView.zoneRects(in: view.bounds)
        #expect(Set(entries.map(\.zone)) == Set(FloatingPaneCardView.Zone.allCases))
        for (index, entry) in entries.enumerated() {
            #expect(view.zone(at: CGPoint(x: entry.rect.midX, y: entry.rect.midY)) == entry.zone, "\(entry.zone) \(entry.rect)")
            for other in entries[(index + 1)...] {
                #expect(!entry.rect.intersects(other.rect), "\(entry.zone) \(entry.rect) and \(other.zone) \(other.rect)")
            }
        }
        let inner = LayoutFloatingPane.paneRect(inCard: view.bounds)
        let area = entries.reduce(0) { $0 + $1.rect.width * $1.rect.height }
        #expect(area == view.bounds.width * view.bounds.height - inner.width * inner.height)
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

    /// The view shows a drag's frame until the release, and tells a new frame from a new list of panes.
    @Test func theViewStateShowsADragAndTellsWhatChanged() {
        let first = LayoutFloatingPane(pane: pane, frame: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4))
        let second = LayoutFloatingPane(pane: other, frame: CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3))
        var state = FloatingPanesState()
        #expect(state.takeChange() == .none)
        state.list = [first, second]
        #expect(state.takeChange() == .panes)
        #expect(state.takeChange() == .none)
        state.list[0].frame.origin.x = 0.2
        #expect(state.takeChange() == .frames)
        state.list = [state.list[1], state.list[0]]
        #expect(state.takeChange() == .panes, "the order is the order back to front")

        let dragged = CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3)
        state.drag = FloatingPaneDrag(pane: other, zone: .move, startPoint: .zero, startCard: .zero, frame: dragged)
        #expect(state.shown.map(\.pane) == [other, pane])
        #expect(state.shown[0].frame == dragged)
        #expect(state.shown[1] == state.list[1])
        state.drag = nil
        #expect(state.shown == state.list)
    }
}
