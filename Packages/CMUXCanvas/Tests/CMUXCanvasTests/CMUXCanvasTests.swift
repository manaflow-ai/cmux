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

    func testSceneSortsFocusedSurfaceAboveEqualZIndexSurfaces() throws {
        let focusedID = LayoutItemID(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        let backgroundID = LayoutItemID(id: try XCTUnwrap(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")))
        let scene = CanvasScene(
            viewport: CanvasViewport(visibleRect: PixelRect(x: 0, y: 0, width: 800, height: 600), scale: 1),
            viewportSize: CGSize(width: 800, height: 600),
            surfaces: [
                CanvasSurfaceDescriptor(
                    id: focusedID,
                    kind: .terminal,
                    frame: PixelRect(x: 0, y: 0, width: 400, height: 300),
                    zIndex: 1,
                    isFocused: true
                ),
                CanvasSurfaceDescriptor(
                    id: backgroundID,
                    kind: .browser,
                    frame: PixelRect(x: 0, y: 0, width: 400, height: 300),
                    zIndex: 1
                ),
            ]
        )

        XCTAssertEqual(scene.surfaces.map(\.id), [backgroundID, focusedID])
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

    func testShellRenderPlanBuildsGridAndSurfaceChrome() {
        let activeID = LayoutItemID()
        let inactiveID = LayoutItemID()
        let style = CanvasShellStyle(
            background: CanvasColor(red: 0.1, green: 0.1, blue: 0.1),
            cardFill: CanvasColor(red: 0.2, green: 0.2, blue: 0.2),
            headerFill: CanvasColor(red: 0.3, green: 0.3, blue: 0.3),
            border: CanvasColor(red: 0.4, green: 0.4, blue: 0.4),
            focusedBorder: CanvasColor(red: 1, green: 1, blue: 1),
            gridMinor: CanvasColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.1),
            gridMajor: CanvasColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 0.2),
            alignmentGuide: CanvasColor(red: 0, green: 0.5, blue: 1),
            shadow: CanvasColor(red: 0, green: 0, blue: 0, alpha: 0.2),
            headerHeight: 20
        )
        let scene = CanvasScene(
            viewport: CanvasViewport(visibleRect: PixelRect(x: 0, y: 0, width: 800, height: 600), scale: 1),
            viewportSize: CGSize(width: 800, height: 600),
            scale: 1,
            minimumSurfaceDisplaySize: CGSize(width: 240, height: 170),
            surfaces: [
                CanvasSurfaceDescriptor(
                    id: activeID,
                    kind: .terminal,
                    frame: PixelRect(x: 20, y: 30, width: 400, height: 300),
                    isFocused: true,
                    renderMode: .nativeOverlay
                ),
                CanvasSurfaceDescriptor(
                    id: inactiveID,
                    kind: .browser,
                    frame: PixelRect(x: 460, y: 30, width: 260, height: 220),
                    isFocused: false,
                    renderMode: .snapshotTexture
                ),
            ],
            alignmentGuides: [
                CanvasAlignmentGuide(axis: .vertical, position: 460, rangeStart: 0, rangeEnd: 600)
            ]
        )

        let plan = CanvasShellRenderPlan(scene: scene, style: style)
        let surfacesByID = Dictionary(uniqueKeysWithValues: plan.surfaces.map { ($0.id, $0) })

        XCTAssertEqual(Set(plan.surfaces.map(\.id)), Set([activeID, inactiveID]))
        XCTAssertEqual(surfacesByID[activeID]?.frame, CGRect(x: 20, y: 30, width: 400, height: 300))
        XCTAssertEqual(surfacesByID[activeID]?.headerFrame, CGRect(x: 20, y: 30, width: 400, height: 20))
        XCTAssertTrue(plan.primitives.contains { primitive in
            if case .stroke(_, _, let color) = primitive, color == style.focusedBorder { return true }
            return false
        })
        XCTAssertTrue(plan.primitives.contains { primitive in
            if case .line(let line) = primitive, line.color == style.alignmentGuide { return true }
            return false
        })
    }

    func testShellRenderPlanUsesMinimumDisplaySizeForZoomedCards() {
        let id = LayoutItemID()
        let scene = CanvasScene(
            viewport: CanvasViewport(visibleRect: PixelRect(x: 0, y: 0, width: 1_600, height: 1_200), scale: 0.25),
            viewportSize: CGSize(width: 400, height: 300),
            scale: 0.25,
            minimumSurfaceDisplaySize: CGSize(width: 240, height: 170),
            surfaces: [
                CanvasSurfaceDescriptor(
                    id: id,
                    kind: .terminal,
                    frame: PixelRect(x: 0, y: 0, width: 400, height: 300),
                    renderMode: .snapshotTexture
                )
            ]
        )

        let plan = CanvasShellRenderPlan(scene: scene)

        XCTAssertEqual(plan.surfaces.first?.frame.size, CGSize(width: 240, height: 170))
    }

    func testShellRenderPlanCullsOffscreenSurfaces() {
        let visibleID = LayoutItemID()
        let hiddenID = LayoutItemID()
        let scene = CanvasScene(
            viewport: CanvasViewport(visibleRect: PixelRect(x: 0, y: 0, width: 800, height: 600), scale: 1),
            viewportSize: CGSize(width: 800, height: 600),
            surfaces: [
                CanvasSurfaceDescriptor(
                    id: visibleID,
                    kind: .terminal,
                    frame: PixelRect(x: 20, y: 30, width: 400, height: 300)
                ),
                CanvasSurfaceDescriptor(
                    id: hiddenID,
                    kind: .browser,
                    frame: PixelRect(x: 5_000, y: 30, width: 400, height: 300)
                ),
            ]
        )

        let plan = CanvasShellRenderPlan(scene: scene)

        XCTAssertEqual(plan.surfaces.map(\.id), [visibleID])
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

    func testViewportAnimationInterpolatesViewportWithEaseOut() {
        let animation = CanvasViewportAnimation(
            startViewport: CanvasViewport(
                visibleRect: PixelRect(x: 0, y: 0, width: 1_200, height: 800),
                scale: 1
            ),
            targetViewport: CanvasViewport(
                visibleRect: PixelRect(x: 600, y: -300, width: 2_400, height: 1_600),
                scale: 0.5
            ),
            startTime: 10,
            duration: 2
        )

        let halfway = animation.viewport(at: 11)
        let expectedProgress = CanvasViewportAnimation.easeOutCubic(0.5)

        XCTAssertEqual(halfway.visibleRect.x, 600 * expectedProgress, accuracy: 0.0001)
        XCTAssertEqual(halfway.visibleRect.y, -300 * expectedProgress, accuracy: 0.0001)
        XCTAssertEqual(halfway.visibleRect.width, 1_200 + (1_200 * expectedProgress), accuracy: 0.0001)
        XCTAssertEqual(halfway.visibleRect.height, 800 + (800 * expectedProgress), accuracy: 0.0001)
        XCTAssertEqual(halfway.scale, 1 - (0.5 * expectedProgress), accuracy: 0.0001)
        XCTAssertFalse(animation.isComplete(at: 11))
        XCTAssertTrue(animation.isComplete(at: 12))
        XCTAssertEqual(animation.viewport(at: 12), animation.targetViewport)
    }

    func testWindowCoordinateMapperUsesCanvasTopLeftCoordinates() throws {
        let frame = try XCTUnwrap(CanvasWindowCoordinateMapper.windowFrame(
            forCanvasRect: CGRect(x: 40, y: 20, width: 320, height: 180),
            inCanvasWindowFrame: CGRect(x: 100, y: 200, width: 1_000, height: 800)
        ))

        XCTAssertEqual(frame, CGRect(x: 140, y: 800, width: 320, height: 180))
    }
}
