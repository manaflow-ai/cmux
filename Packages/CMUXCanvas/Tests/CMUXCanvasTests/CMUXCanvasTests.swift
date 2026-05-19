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

    func testNativeOverlayManagerUsesNativeOnlyForActiveSurfaceAtNativeScale() {
        let activeID = LayoutItemID()
        let previewID = LayoutItemID()
        let scene = CanvasScene(
            viewport: CanvasViewport(visibleRect: PixelRect(x: 0, y: 0, width: 800, height: 600), scale: 1),
            viewportSize: CGSize(width: 800, height: 600),
            scale: 1,
            surfaces: [
                CanvasSurfaceDescriptor(
                    id: activeID,
                    kind: .terminal,
                    frame: PixelRect(x: 100, y: 120, width: 400, height: 300),
                    isFocused: true,
                    renderMode: .nativeOverlay
                ),
                CanvasSurfaceDescriptor(
                    id: previewID,
                    kind: .browser,
                    frame: PixelRect(x: 520, y: 120, width: 400, height: 300),
                    isFocused: false,
                    renderMode: .nativeOverlay
                ),
            ]
        )

        let manager = NativeSurfaceOverlayManager(
            configuration: CanvasNativeOverlayConfiguration(activeSurfaceID: activeID)
        )
        let plan = manager.plan(scene: scene)

        XCTAssertEqual(plan.nativeOverlays.map(\.id), [activeID])
        XCTAssertEqual(plan.textureSurfaces.map(\.id), [previewID])
        XCTAssertEqual(plan.nativeOverlays.first?.frameInWindow, CGRect(x: 100, y: 120, width: 400, height: 300))
    }

    func testNativeOverlayManagerFallsBackToTexturesWhenZoomedOut() {
        let activeID = LayoutItemID()
        let scene = CanvasScene(
            viewport: CanvasViewport(visibleRect: PixelRect(x: 0, y: 0, width: 800, height: 600), scale: 0.5),
            viewportSize: CGSize(width: 800, height: 600),
            scale: 0.5,
            surfaces: [
                CanvasSurfaceDescriptor(
                    id: activeID,
                    kind: .terminal,
                    frame: PixelRect(x: 100, y: 120, width: 400, height: 300),
                    isFocused: true,
                    renderMode: .nativeOverlay
                ),
            ]
        )

        let plan = NativeSurfaceOverlayManager().plan(scene: scene)

        XCTAssertTrue(plan.nativeOverlays.isEmpty)
        XCTAssertEqual(plan.textureSurfaces.map(\.id), [activeID])
    }

    func testSurfaceTextureCacheEvictsLeastRecentlyUsedAndPrunesInvisibleSurfaces() {
        let firstID = LayoutItemID()
        let secondID = LayoutItemID()
        let thirdID = LayoutItemID()
        let firstKey = CanvasSurfaceTextureKey(surfaceID: firstID, kind: .snapshot)
        let secondKey = CanvasSurfaceTextureKey(surfaceID: secondID, kind: .snapshot)
        let thirdKey = CanvasSurfaceTextureKey(surfaceID: thirdID, kind: .live)
        let cache = SurfaceTextureCache(maximumCount: 2)

        cache.store(CanvasSurfaceTextureDescriptor(key: firstKey, pixelSize: CGSize(width: 100, height: 100), scale: 1))
        cache.store(CanvasSurfaceTextureDescriptor(key: secondKey, pixelSize: CGSize(width: 200, height: 100), scale: 1))
        XCTAssertNotNil(cache.descriptor(for: firstKey))
        cache.store(CanvasSurfaceTextureDescriptor(key: thirdKey, pixelSize: CGSize(width: 300, height: 100), scale: 0.5))

        XCTAssertNotNil(cache.descriptor(for: firstKey))
        XCTAssertNil(cache.descriptor(for: secondKey))
        XCTAssertNotNil(cache.descriptor(for: thirdKey))

        cache.removeSurfaces(notIn: [thirdID])

        XCTAssertNil(cache.descriptor(for: firstKey))
        XCTAssertNotNil(cache.descriptor(for: thirdKey))
    }
}
