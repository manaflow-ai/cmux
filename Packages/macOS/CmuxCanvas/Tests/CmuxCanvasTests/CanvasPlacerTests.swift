import Testing
@testable import CmuxCanvas

import Foundation

struct CanvasPlacerTests {
    private let metrics = CanvasMetrics(gap: 16, snapThreshold: 8)
    private var placer: CanvasPlacer { CanvasPlacer(metrics: metrics) }
    private let size = CanvasSize(width: 300, height: 200)

    @Test func emptyCanvasPlacesAtOriginOrAnchor() {
        #expect(
            placer.frameForNewPane(size: size, near: nil, avoiding: []) ==
                CanvasRect(x: 0, y: 0, width: 300, height: 200)
        )
        let anchor = CanvasRect(x: 50, y: 60, width: 10, height: 10)
        #expect(
            placer.frameForNewPane(size: size, near: anchor, avoiding: []).origin ==
                CanvasPoint(x: 50, y: 60)
        )
    }

    @Test func placesRightOfAnchorAtGap() {
        let anchor = CanvasRect(x: 0, y: 0, width: 300, height: 200)
        let frame = placer.frameForNewPane(size: size, near: anchor, avoiding: [anchor])
        #expect(frame == CanvasRect(x: 316, y: 0, width: 300, height: 200))
    }

    @Test func fallsThroughRightBelowLeftAbove() {
        let anchor = CanvasRect(x: 1000, y: 1000, width: 300, height: 200)
        let right = CanvasRect(x: 1316, y: 1000, width: 300, height: 200)
        let below = CanvasRect(x: 1000, y: 1216, width: 300, height: 200)
        let frame = placer.frameForNewPane(
            size: size,
            near: anchor,
            avoiding: [anchor, right, below]
        )
        #expect(frame == CanvasRect(x: 684, y: 1000, width: 300, height: 200))
    }

    @Test func newPaneKeepsGapDistanceFromAllPanes() {
        let anchor = CanvasRect(x: 0, y: 0, width: 300, height: 200)
        // Pane sitting just right of the anchor but slightly offset, blocking the gap slot.
        let blocker = CanvasRect(x: 320, y: 10, width: 300, height: 200)
        let frame = placer.frameForNewPane(size: size, near: anchor, avoiding: [anchor, blocker])
        for existing in [anchor, blocker] {
            #expect(!frame.expandedBy(metrics.gap - 0.5).intersects(existing))
        }
    }

    @Test func noAnchorPlacesRightOfContent() {
        let existing = [
            CanvasRect(x: 0, y: 40, width: 300, height: 200),
            CanvasRect(x: 350, y: 0, width: 300, height: 200),
        ]
        let frame = placer.frameForNewPane(size: size, near: nil, avoiding: existing)
        #expect(frame == CanvasRect(x: 666, y: 0, width: 300, height: 200))
    }

    @Test func crowdedNeighborhoodFallsBackOutsideContent() {
        // Surround the anchor completely so every nearby slot is taken.
        let anchor = CanvasRect(x: 0, y: 0, width: 100, height: 100)
        var existing = [anchor]
        for dx in stride(from: -1300.0, through: 6000, by: 100) {
            for dy in stride(from: -1300.0, through: 2600, by: 100) where !(dx == 0 && dy == 0) {
                existing.append(CanvasRect(x: dx, y: dy, width: 100, height: 100))
            }
        }
        let frame = placer.frameForNewPane(size: size, near: anchor, avoiding: existing)
        for rect in existing {
            #expect(!frame.expandedBy(metrics.gap - 0.5).intersects(rect))
        }
    }
}
