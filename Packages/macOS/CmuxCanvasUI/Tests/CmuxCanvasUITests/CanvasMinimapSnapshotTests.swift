import CoreGraphics
import Foundation
import Testing
import CmuxCanvas
@testable import CmuxCanvasUI

@Suite("CanvasMinimapSnapshot")
struct CanvasMinimapSnapshotTests {
    @Test func navigationBoundsIncludeContentAndVisibleViewport() {
        let pane = CanvasMinimapPaneSnapshot(
            id: CanvasPaneID(rawValue: UUID()),
            frame: CGRect(x: 0, y: 0, width: 300, height: 200)
        )
        let snapshot = CanvasMinimapSnapshot(
            panes: [pane],
            visibleRect: CGRect(x: 900, y: 500, width: 400, height: 300),
            focusedPaneID: pane.id
        )

        #expect(snapshot.navigationBounds == CGRect(x: 0, y: 0, width: 1300, height: 800))
        #expect(snapshot.shouldShow)
    }

    @Test func projectionCentersLetterboxedContent() {
        let pane = CanvasMinimapPaneSnapshot(
            id: CanvasPaneID(rawValue: UUID()),
            frame: CGRect(x: 0, y: 0, width: 200, height: 100)
        )
        let snapshot = CanvasMinimapSnapshot(
            panes: [pane],
            visibleRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            focusedPaneID: nil
        )

        let projection = snapshot.projection(in: CGRect(x: 0, y: 0, width: 100, height: 100))

        #expect(projection.scale == 0.5)
        #expect(projection.origin == CGPoint(x: 0, y: 25))
    }

    @Test func projectedNavigationBoundsExcludeLetterboxPadding() {
        let pane = CanvasMinimapPaneSnapshot(
            id: CanvasPaneID(rawValue: UUID()),
            frame: CGRect(x: 0, y: 0, width: 200, height: 100)
        )
        let snapshot = CanvasMinimapSnapshot(
            panes: [pane],
            visibleRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            focusedPaneID: nil
        )

        let projected = snapshot.projectedNavigationBounds(
            in: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        #expect(projected == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    @Test func pointMappingRoundTripsThroughProjection() {
        let pane = CanvasMinimapPaneSnapshot(
            id: CanvasPaneID(rawValue: UUID()),
            frame: CGRect(x: -200, y: 100, width: 400, height: 300)
        )
        let snapshot = CanvasMinimapSnapshot(
            panes: [pane],
            visibleRect: CGRect(x: -100, y: 200, width: 100, height: 100),
            focusedPaneID: nil
        )
        let drawingRect = CGRect(x: 10, y: 10, width: 160, height: 80)
        let canvasPoint = CGPoint(x: 20, y: 250)
        let minimapRect = snapshot.minimapRect(
            for: CGRect(origin: canvasPoint, size: CGSize(width: 1, height: 1)),
            in: drawingRect
        )

        let mapped = snapshot.canvasPoint(for: minimapRect.origin, in: drawingRect)

        #expect(abs(mapped.x - canvasPoint.x) < 0.0001)
        #expect(abs(mapped.y - canvasPoint.y) < 0.0001)
    }

    @Test func singlePaneThatFitsViewportStaysHidden() {
        let pane = CanvasMinimapPaneSnapshot(
            id: CanvasPaneID(rawValue: UUID()),
            frame: CGRect(x: 40, y: 40, width: 120, height: 90)
        )
        let snapshot = CanvasMinimapSnapshot(
            panes: [pane],
            visibleRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            focusedPaneID: nil
        )

        #expect(!snapshot.shouldShow)
    }

    @Test func degenerateViewportStaysHidden() {
        let pane = CanvasMinimapPaneSnapshot(
            id: CanvasPaneID(rawValue: UUID()),
            frame: CGRect(x: 0, y: 0, width: 120, height: 90)
        )
        let snapshot = CanvasMinimapSnapshot(
            panes: [pane, pane],
            visibleRect: .zero,
            focusedPaneID: nil
        )

        #expect(!snapshot.shouldShow)
    }
}
