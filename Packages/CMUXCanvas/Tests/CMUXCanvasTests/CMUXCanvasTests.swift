import CMUXCanvas
import CMUXLayout
import CoreGraphics
import XCTest

final class CMUXCanvasTests: XCTestCase {
    func testSceneSortsAndFiltersVisibleSurfaces() {
        let visibleID = LayoutItemID()
        let hiddenID = LayoutItemID()
        let frontID = LayoutItemID()
        let viewport = CanvasViewport(
            visibleRect: PixelRect(x: 0, y: 0, width: 500, height: 300),
            scale: 1
        )
        let scene = CanvasScene(
            viewport: viewport,
            viewportSize: CGSize(width: 500, height: 300),
            surfaces: [
                CanvasSurfaceDescriptor(
                    id: frontID,
                    kind: .browser,
                    frame: PixelRect(x: 20, y: 20, width: 100, height: 100),
                    zIndex: 10
                ),
                CanvasSurfaceDescriptor(
                    id: hiddenID,
                    kind: .terminal,
                    frame: PixelRect(x: 900, y: 20, width: 100, height: 100),
                    zIndex: 1
                ),
                CanvasSurfaceDescriptor(
                    id: visibleID,
                    kind: .terminal,
                    frame: PixelRect(x: 10, y: 10, width: 100, height: 100),
                    zIndex: 1
                ),
            ]
        )

        XCTAssertEqual(scene.surfaces.map(\.zIndex), [1, 1, 10])
        XCTAssertEqual(Set(scene.visibleSurfaces.map(\.id)), Set([visibleID, frontID]))
    }

    func testInputPanMatchesWorkspaceViewportMathAndReturnsScreenDelta() {
        let controller = CanvasInputController(
            viewport: CanvasViewport(
                visibleRect: PixelRect(x: 100, y: 50, width: 600, height: 400),
                scale: 0.5
            )
        )

        let update = controller.pan(
            screenDelta: CGSize(width: 40, height: -20),
            scale: 0.5,
            viewportSize: CGSize(width: 500, height: 300)
        )

        XCTAssertEqual(update.phase, .panning)
        XCTAssertEqual(update.surfaceScreenDelta.width, 40)
        XCTAssertEqual(update.surfaceScreenDelta.height, -20)
        XCTAssertEqual(update.viewport.visibleRect.x, 20)
        XCTAssertEqual(update.viewport.visibleRect.y, 90)
        XCTAssertEqual(update.viewport.visibleRect.width, 1_000)
        XCTAssertEqual(update.viewport.visibleRect.height, 600)
    }

    func testInputZoomKeepsAnchorStable() {
        let controller = CanvasInputController(
            viewport: CanvasViewport(
                visibleRect: PixelRect(x: 100, y: 200, width: 500, height: 300),
                scale: 1
            )
        )

        let update = controller.setScale(
            0.5,
            viewportSize: CGSize(width: 500, height: 300),
            anchorScreenPoint: CGPoint(x: 100, y: 50)
        )

        XCTAssertEqual(update.phase, .zooming)
        XCTAssertEqual(update.viewport.scale, 0.5)
        XCTAssertEqual(update.viewport.visibleRect.x, 0)
        XCTAssertEqual(update.viewport.visibleRect.y, 150)
        XCTAssertEqual(update.viewport.visibleRect.width, 1_000)
        XCTAssertEqual(update.viewport.visibleRect.height, 600)
    }

    func testFrameSchedulerCoalescesFrames() {
        var scheduler = CanvasFrameScheduler()

        XCTAssertFalse(scheduler.consumeFrame())

        scheduler.markNeedsRender()
        scheduler.markNeedsRender()

        XCTAssertTrue(scheduler.consumeFrame())
        XCTAssertEqual(scheduler.frameNumber, 1)
        XCTAssertFalse(scheduler.consumeFrame())
    }
}
