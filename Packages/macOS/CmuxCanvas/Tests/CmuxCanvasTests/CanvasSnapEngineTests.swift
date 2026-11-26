import Testing
@testable import CmuxCanvas

import Foundation

struct CanvasSnapEngineTests {
    private let metrics = CanvasMetrics(
        gap: 16,
        snapThreshold: 8,
        minPaneSize: CanvasSize(width: 200, height: 120)
    )
    private var engine: CanvasSnapEngine { CanvasSnapEngine(metrics: metrics) }
    private let neighbor = CanvasRect(x: 0, y: 0, width: 300, height: 200)

    // MARK: Move

    @Test func moveSnapsLeftEdgeToNeighborLeft() {
        let proposed = CanvasRect(x: 5, y: 400, width: 300, height: 200)
        let result = engine.snapForMove(proposed: proposed, neighbors: [neighbor])
        #expect(result.frame.x == 0)
        #expect(result.frame.y == 400)
        #expect(result.guides.count == 1)
        #expect(result.guides[0].axis == .vertical)
        #expect(result.guides[0].position == 0)
        // Guide spans both rects vertically.
        #expect(result.guides[0].span == 0...600)
    }

    @Test func moveSnapsToGapAdjacency() {
        // Neighbor right edge at 300, so gap position for our left edge is 316.
        // Placed far below the neighbor so only the x axis snaps.
        let proposed = CanvasRect(x: 312, y: 500, width: 300, height: 200)
        let result = engine.snapForMove(proposed: proposed, neighbors: [neighbor])
        #expect(result.frame.x == 316)
        #expect(result.frame.y == 500)
        #expect(result.guides.count == 1)
        #expect(result.guides[0].position == 316)
    }

    @Test func moveSnapsCentersOnBothAxes() {
        let proposed = CanvasRect(x: 3, y: 102, width: 300, height: 200)
        // x: aligns left (delta -3); y: neighbor midY=100 vs proposed midY=202 -> too far,
        // but proposed.minY=102 is not near neighbor edges either... use center-y target:
        // neighbor.midY = 100, proposed.midY = 202 -> delta 102, no snap on y.
        let result = engine.snapForMove(proposed: proposed, neighbors: [neighbor])
        #expect(result.frame.x == 0)
        #expect(result.frame.y == 102)
        #expect(result.guides.count == 1)
    }

    @Test func moveBeyondThresholdDoesNotSnap() {
        let proposed = CanvasRect(x: 9, y: 400, width: 300, height: 200)
        let result = engine.snapForMove(proposed: proposed, neighbors: [neighbor])
        #expect(result.frame == proposed)
        #expect(result.guides.isEmpty)
    }

    @Test func moveAtExactThresholdSnaps() {
        let proposed = CanvasRect(x: 8, y: 400, width: 300, height: 200)
        let result = engine.snapForMove(proposed: proposed, neighbors: [neighbor])
        #expect(result.frame.x == 0)
    }

    @Test func movePrefersEdgeAlignmentOverCenterOnTie() {
        // A 16pt-narrower pane: left-align delta and center-align delta can tie.
        // Construct: neighbor left=0 width=300. Pane width=300 so center==left tie occurs at x=0.
        // Use distinct neighbor producing equidistant edge and center candidates.
        let other = CanvasRect(x: 100, y: 0, width: 100, height: 100)
        // Pane at x=96 width=108: left->100 delta 4; center (150) vs pane mid (150) delta 0.
        // Make a real tie: pane x=98 width=100 -> left delta 2, center delta 2.
        let proposed = CanvasRect(x: 98, y: 300, width: 100, height: 100)
        let result = engine.snapForMove(proposed: proposed, neighbors: [other])
        #expect(result.frame.x == 100)
        #expect(result.guides[0].position == 100)
    }

    @Test func moveWithNoNeighborsReturnsProposed() {
        let proposed = CanvasRect(x: 42, y: 42, width: 300, height: 200)
        let result = engine.snapForMove(proposed: proposed, neighbors: [])
        #expect(result.frame == proposed)
        #expect(result.guides.isEmpty)
    }

    @Test func moveSnapsBothAxesIndependently() {
        let proposed = CanvasRect(x: 314, y: 3, width: 300, height: 200)
        let result = engine.snapForMove(proposed: proposed, neighbors: [neighbor])
        #expect(result.frame.x == 316)
        #expect(result.frame.y == 0)
        #expect(result.guides.count == 2)
        #expect(result.guides.contains(where: { $0.axis == .vertical }))
        #expect(result.guides.contains(where: { $0.axis == .horizontal }))
    }

    // MARK: Resize

    @Test func resizeRightEdgeSnapsToNeighborRight() {
        let proposed = CanvasRect(x: 0, y: 400, width: 295, height: 200)
        let result = engine.snapForResize(proposed: proposed, edges: .right, neighbors: [neighbor])
        #expect(result.frame == CanvasRect(x: 0, y: 400, width: 300, height: 200))
        #expect(result.guides.count == 1)
        #expect(result.guides[0].position == 300)
    }

    @Test func resizeLeftEdgeSnapsToGapBesideNeighbor() {
        // Neighbor maxX=300; gap target for left edge = 316.
        let proposed = CanvasRect(x: 320, y: 0, width: 300, height: 200)
        let result = engine.snapForResize(proposed: proposed, edges: .left, neighbors: [neighbor])
        #expect(result.frame.minX == 316)
        // Right edge stays fixed.
        #expect(result.frame.maxX == 620)
    }

    @Test func resizeClampsToMinimumSize() {
        let proposed = CanvasRect(x: 0, y: 0, width: 150, height: 80)
        let result = engine.snapForResize(
            proposed: proposed,
            edges: [.right, .bottom],
            neighbors: []
        )
        #expect(result.frame.width == 200)
        #expect(result.frame.height == 120)
        #expect(result.frame.origin == proposed.origin)
    }

    @Test func resizeLeftClampKeepsRightEdgeFixed() {
        let proposed = CanvasRect(x: 450, y: 0, width: 150, height: 200)
        let result = engine.snapForResize(proposed: proposed, edges: .left, neighbors: [])
        #expect(result.frame.maxX == 600)
        #expect(result.frame.width == 200)
        #expect(result.frame.minX == 400)
    }

    @Test func resizeClampDropsUndoneSnapGuides() {
        // Snap would put the left edge at neighbor.minX, but that violates min width,
        // so the clamp wins and the guide disappears.
        let neighbor = CanvasRect(x: 395, y: 0, width: 100, height: 100)
        let proposed = CanvasRect(x: 400, y: 0, width: 150, height: 200)
        let result = engine.snapForResize(proposed: proposed, edges: .left, neighbors: [neighbor])
        #expect(result.frame.width == 200)
        #expect(result.frame.maxX == 550)
        #expect(result.guides.isEmpty)
    }

    @Test func resizeTopAndCornerCombination() {
        let proposed = CanvasRect(x: 0, y: 203, width: 300, height: 197)
        // Top edge near neighbor.maxY (200): snap to 200? Gap target is 216.
        let result = engine.snapForResize(
            proposed: proposed,
            edges: [.top, .right],
            neighbors: [neighbor]
        )
        // Align-top target is neighbor.minY=0 (too far); gap target 216 is 13 away (no).
        // neighbor.maxY+gap=216 delta 13 > threshold; align target neighbor.minY=0 too far.
        // So top edge does not snap; right edge to neighbor.maxX=300 (delta 0) stays.
        #expect(result.frame == proposed)
    }

    @Test func resizeWithoutSnapBeyondThresholdReturnsProposed() {
        let proposed = CanvasRect(x: 0, y: 400, width: 280, height: 200)
        let result = engine.snapForResize(proposed: proposed, edges: .right, neighbors: [neighbor])
        #expect(result.frame == proposed)
        #expect(result.guides.isEmpty)
    }
}
