@testable import CMUXCanvas
import CMUXLayout
import CoreGraphics
#if canImport(IOSurface)
import IOSurface
#endif
#if canImport(Metal)
import Metal
#endif
import XCTest

final class CMUXCanvasTests: XCTestCase {
#if canImport(Metal)
    func testMetalTexturePipelineUsesPremultipliedAlphaBlending() {
        let descriptor = MTLRenderPipelineDescriptor()
        let colorAttachment = descriptor.colorAttachments[0]

        CanvasMetalPremultipliedBlending.configure(colorAttachment)

        XCTAssertEqual(colorAttachment?.isBlendingEnabled, true)
        XCTAssertEqual(colorAttachment?.sourceRGBBlendFactor, .one)
        XCTAssertEqual(colorAttachment?.destinationRGBBlendFactor, .oneMinusSourceAlpha)
        XCTAssertEqual(colorAttachment?.rgbBlendOperation, .add)
        XCTAssertEqual(colorAttachment?.sourceAlphaBlendFactor, .one)
        XCTAssertEqual(colorAttachment?.destinationAlphaBlendFactor, .oneMinusSourceAlpha)
        XCTAssertEqual(colorAttachment?.alphaBlendOperation, .add)
    }

    func testCanvasMetalShaderLibraryProvidesPrecompiledFunctions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        XCTAssertNotNil(
            CanvasMetalShaderLibrary.packageLibraryURL(),
            "CMUXCanvas should ship a compiled package metallib instead of falling back to the app target default library"
        )
        guard let library = CanvasMetalShaderLibrary.makeLibrary(device: device) else {
            XCTFail("Precompiled Metal library unavailable in this package test host")
            return
        }

        XCTAssertNotNil(library.makeFunction(name: "cmux_canvas_vertex"))
        XCTAssertNotNil(library.makeFunction(name: "cmux_canvas_fragment"))
        XCTAssertNotNil(library.makeFunction(name: "cmux_canvas_texture_vertex"))
        XCTAssertNotNil(library.makeFunction(name: "cmux_canvas_texture_fragment"))
        XCTAssertNotNil(library.makeFunction(name: "canvas_iosurface_vertex"))
        XCTAssertNotNil(library.makeFunction(name: "canvas_iosurface_fragment"))
    }
#endif

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
        let camera = CanvasCamera(
            viewport: CanvasViewport(
                visibleRect: PixelRect(x: 100, y: 50, width: 600, height: 400),
                scale: 0.5
            ),
            viewportSize: CGSize(width: 500, height: 300)
        )

        let next = CanvasPresentationEngine.camera(
            byApplying: .pan(screenDelta: CGSize(width: 40, height: -20)),
            to: camera
        ).viewport

        XCTAssertEqual(next.visibleRect.x, 20)
        XCTAssertEqual(next.visibleRect.y, 90)
        XCTAssertEqual(next.visibleRect.width, 1_000)
        XCTAssertEqual(next.visibleRect.height, 600)
    }

    func testInputZoomKeepsAnchorStable() {
        let camera = CanvasCamera(
            viewport: CanvasViewport(
                visibleRect: PixelRect(x: 100, y: 200, width: 500, height: 300),
                scale: 1
            ),
            viewportSize: CGSize(width: 500, height: 300)
        )

        let next = CanvasPresentationEngine.camera(
            byApplying: .zoom(scale: 0.5, anchorScreenPoint: CGPoint(x: 100, y: 50)),
            to: camera
        ).viewport

        XCTAssertEqual(next.scale, 0.5)
        XCTAssertEqual(next.visibleRect.x, 0)
        XCTAssertEqual(next.visibleRect.y, 150)
        XCTAssertEqual(next.visibleRect.width, 1_000)
        XCTAssertEqual(next.visibleRect.height, 600)
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

    func testBitmapTextureSourceDoesNotRequireContinuousRendering() throws {
        let image = try XCTUnwrap(Self.makeTestImage())
        let source = CanvasSurfaceTextureSource(id: LayoutItemID(), image: image, generation: 1)

        XCTAssertFalse(source.requiresContinuousRendering)
    }

    func testStaticBitmapTexturesUseOneShotMetalDisplayMode() throws {
        let image = try XCTUnwrap(Self.makeTestImage())
        let source = CanvasSurfaceTextureSource(id: LayoutItemID(), image: image, generation: 1)

        let mode = CanvasMetalRenderLoopMode.resolve(surfaceTextures: [source])

        XCTAssertEqual(mode.isPaused, true)
        XCTAssertEqual(mode.enableSetNeedsDisplay, true)
        XCTAssertEqual(mode.requestsImmediateDisplay, true)
    }

    func testCameraMotionCanForceContinuousMetalDisplayModeForStaticTextures() throws {
        let image = try XCTUnwrap(Self.makeTestImage())
        let source = CanvasSurfaceTextureSource(id: LayoutItemID(), image: image, generation: 1)

        let mode = CanvasMetalRenderLoopMode.resolve(
            surfaceTextures: [source],
            forceContinuousRender: true
        )

        XCTAssertEqual(mode.isPaused, false)
        XCTAssertEqual(mode.enableSetNeedsDisplay, false)
        XCTAssertEqual(mode.requestsImmediateDisplay, false)
    }

#if canImport(IOSurface)
    func testIOSurfaceTexturesUseContinuousMetalDisplayMode() throws {
        let properties = [
            kIOSurfaceWidth: 4,
            kIOSurfaceHeight: 4,
            kIOSurfaceBytesPerElement: 4,
        ] as CFDictionary
        let surface = try XCTUnwrap(IOSurfaceCreate(properties))
        let source = CanvasSurfaceTextureSource(id: LayoutItemID(), surface: surface)

        XCTAssertTrue(source.requiresContinuousRendering)

        let mode = CanvasMetalRenderLoopMode.resolve(surfaceTextures: [source])

        XCTAssertEqual(mode.isPaused, false)
        XCTAssertEqual(mode.enableSetNeedsDisplay, false)
        XCTAssertEqual(mode.requestsImmediateDisplay, false)
    }
#endif

    func testSurfaceTextureSourceIndexAllowsDuplicateIDs() throws {
        let image = try XCTUnwrap(Self.makeTestImage())
        let id = LayoutItemID()
        let older = CanvasSurfaceTextureSource(id: id, image: image, generation: 1, contentMode: .fit)
        let newer = CanvasSurfaceTextureSource(id: id, image: image, generation: 2, contentMode: .fill)

        let sources = CanvasSurfaceTextureSourceIndex.makeSourcesByID([older, newer])

        XCTAssertEqual(sources.count, 1)
        guard case .bitmap(_, let generation) = sources[id]?.backing else {
            return XCTFail("Expected bitmap source")
        }
        XCTAssertEqual(generation, 2)
        XCTAssertEqual(sources[id]?.contentMode, .fill)
    }

    func testStretchTextureModeUsesExactCanvasContentFrame() {
        let contentFrame = CGRect(x: 20, y: 30, width: 300, height: 180)
        let textureSize = CGSize(width: 1200, height: 780)

        let frame = CanvasMetalTextureFrameResolver.frame(
            in: contentFrame,
            textureSize: textureSize,
            contentMode: .stretch
        )

        XCTAssertEqual(frame, contentFrame)
    }

    func testFitTextureModeCanLetterboxWhenAspectRatiosDiffer() {
        let contentFrame = CGRect(x: 20, y: 30, width: 300, height: 180)
        let textureSize = CGSize(width: 1200, height: 780)

        let frame = CanvasMetalTextureFrameResolver.frame(
            in: contentFrame,
            textureSize: textureSize,
            contentMode: .fit
        )

        XCTAssertLessThan(frame.width, contentFrame.width)
        XCTAssertEqual(frame.height, contentFrame.height, accuracy: 0.001)
    }

    func testNativeOverlayManagerUsesNativeOnlyForActiveSurfaceAtNativeScale() {
        let activeID = LayoutItemID()
        let previewID = LayoutItemID()
        let document = CanvasDocument(
            policy: .freeform,
            viewport: CanvasViewport(visibleRect: PixelRect(x: 0, y: 0, width: 800, height: 600), scale: 1),
            items: [
                CanvasItem(
                    id: activeID,
                    content: .pane(PaneID()),
                    frame: PixelRect(x: 100, y: 120, width: 400, height: 300),
                    isNativeResolution: true
                ),
                CanvasItem(
                    id: previewID,
                    content: .pane(PaneID()),
                    frame: PixelRect(x: 520, y: 120, width: 400, height: 300),
                    isNativeResolution: true
                ),
            ]
        )

        let presentation = CanvasPresentationEngine.presentation(
            document: document,
            viewportSize: CGSize(width: 800, height: 600),
            focusedItemID: activeID,
            activeItemID: activeID,
            contentKinds: [activeID: .terminal, previewID: .browser],
            configuration: CanvasPresentationConfiguration(
                nativeOverlayConfiguration: CanvasNativeOverlayConfiguration(activeSurfaceID: activeID)
            )
        )

        XCTAssertEqual(presentation.nativeOverlays.map(\.id), [activeID])
        XCTAssertEqual(presentation.textureSurfaces.map(\.id), [previewID])
        XCTAssertEqual(presentation.nativeOverlays.first?.frameInWindow, CGRect(x: 100, y: 120, width: 400, height: 300))
    }

    private static func makeTestImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels: [UInt8] = [
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            255, 255, 255, 255,
        ]
        return pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            return context?.makeImage()
        }
    }

    func testNativeOverlayManagerFallsBackToTexturesWhenZoomedOut() {
        let activeID = LayoutItemID()
        let document = CanvasDocument(
            policy: .freeform,
            viewport: CanvasViewport(visibleRect: PixelRect(x: 0, y: 0, width: 800, height: 600), scale: 0.5),
            items: [
                CanvasItem(
                    id: activeID,
                    content: .pane(PaneID()),
                    frame: PixelRect(x: 100, y: 120, width: 400, height: 300),
                    isNativeResolution: true
                ),
            ]
        )

        let presentation = CanvasPresentationEngine.presentation(
            document: document,
            viewportSize: CGSize(width: 800, height: 600),
            focusedItemID: activeID,
            activeItemID: activeID,
            contentKinds: [activeID: .terminal]
        )

        XCTAssertTrue(presentation.nativeOverlays.isEmpty)
        XCTAssertEqual(presentation.textureSurfaces.map(\.id), [activeID])
    }

    func testNativeOverlayManagerUsesSharedNativeThreshold() {
        let activeID = LayoutItemID()
        let item = CanvasItem(
            id: activeID,
            content: .pane(PaneID()),
            frame: PixelRect(x: 100, y: 120, width: 400, height: 300),
            isNativeResolution: true
        )

        let previewPlan = CanvasPresentationEngine.presentation(
            document: CanvasDocument(
                policy: .freeform,
                viewport: CanvasViewport(
                    visibleRect: PixelRect(x: 0, y: 0, width: 800, height: 600),
                    scale: CanvasViewportZoom.nativeOverlayMinimumScale - 0.001
                ),
                items: [item]
            ),
            viewportSize: CGSize(width: 800, height: 600),
            focusedItemID: activeID,
            activeItemID: activeID,
            contentKinds: [activeID: .terminal],
            configuration: CanvasPresentationConfiguration(
                nativeOverlayConfiguration: CanvasNativeOverlayConfiguration(activeSurfaceID: activeID)
            )
        )
        let nativePlan = CanvasPresentationEngine.presentation(
            document: CanvasDocument(
                policy: .freeform,
                viewport: CanvasViewport(
                    visibleRect: PixelRect(x: 0, y: 0, width: 800, height: 600),
                    scale: CanvasViewportZoom.nativeOverlayMinimumScale
                ),
                items: [item]
            ),
            viewportSize: CGSize(width: 800, height: 600),
            focusedItemID: activeID,
            activeItemID: activeID,
            contentKinds: [activeID: .terminal],
            configuration: CanvasPresentationConfiguration(
                nativeOverlayConfiguration: CanvasNativeOverlayConfiguration(activeSurfaceID: activeID)
            )
        )

        XCTAssertTrue(previewPlan.nativeOverlays.isEmpty)
        XCTAssertEqual(previewPlan.textureSurfaces.map(\.id), [activeID])
        XCTAssertEqual(nativePlan.nativeOverlays.map(\.id), [activeID])
        XCTAssertTrue(nativePlan.textureSurfaces.isEmpty)
    }

    func testSceneCanConsumePresentationStateWithoutRecomputingPolicy() {
        let activeID = LayoutItemID()
        let document = CanvasDocument(
            policy: .freeform,
            viewport: CanvasViewport(
                visibleRect: PixelRect(x: 0, y: 0, width: 800, height: 600),
                scale: 1
            ),
            items: [
                CanvasItem(
                    id: activeID,
                    content: .pane(PaneID()),
                    frame: PixelRect(x: 40, y: 80, width: 320, height: 220)
                )
            ]
        )
        let presentation = CanvasPresentationEngine.presentation(
            document: document,
            viewportSize: CGSize(width: 800, height: 600),
            focusedItemID: activeID,
            activeItemID: activeID,
            contentKinds: [activeID: .terminal]
        )

        let scene = CanvasScene(presentation: presentation, padding: 0)

        XCTAssertEqual(scene.visibleSurfaces.map(\.id), [activeID])
        XCTAssertEqual(scene.surfaceScreenFrame(for: scene.surfaces[0]), CGRect(x: 40, y: 80, width: 320, height: 220))
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
            if case .fill(let rect) = primitive, rect.color == style.cardFill { return true }
            return false
        })
        XCTAssertFalse(plan.primitives.contains { primitive in
            if case .stroke = primitive { return true }
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

    func testAnimatedViewportDrivesShellAndPortalFramesFromSameTransform() throws {
        let id = LayoutItemID(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000123")))
        let descriptor = CanvasSurfaceDescriptor(
            id: id,
            kind: .terminal,
            frame: PixelRect(x: 320, y: 180, width: 500, height: 360),
            isFocused: true,
            renderMode: .nativeOverlay
        )
        let animation = CanvasViewportAnimation(
            startViewport: CanvasViewport(
                visibleRect: PixelRect(x: 0, y: 0, width: 1_200, height: 800),
                scale: 1
            ),
            targetViewport: CanvasViewport(
                visibleRect: PixelRect(x: 180, y: 120, width: 2_400, height: 1_600),
                scale: 0.5
            ),
            startTime: 10,
            duration: 0.2
        )
        let viewportSize = CGSize(width: 1_200, height: 800)
        let canvasWindowFrame = CGRect(x: 80, y: 120, width: 1_200, height: 800)
        let style = CanvasShellStyle(headerHeight: 20)

        for time in [10.0, 10.1, 10.2] {
            let viewport = animation.viewport(at: time)
            let scale = CGFloat(CanvasViewportZoom.presentationScale(for: viewport))
            let scene = CanvasScene(
                viewport: viewport,
                viewportSize: viewportSize,
                scale: scale,
                surfaces: [descriptor]
            )
            let shellSurface = try XCTUnwrap(CanvasShellRenderPlan(scene: scene, style: style).surfaces.first)
            let screenFrame = scene.surfaceScreenFrame(for: descriptor)
            let portalFrame = try XCTUnwrap(CanvasWindowCoordinateMapper.windowFrame(
                forCanvasRect: shellSurface.contentFrame,
                inCanvasWindowFrame: canvasWindowFrame
            ))

            XCTAssertEqual(shellSurface.frame.minX, screenFrame.minX, accuracy: 0.0001)
            XCTAssertEqual(shellSurface.frame.minY, screenFrame.minY, accuracy: 0.0001)
            XCTAssertEqual(shellSurface.frame.width, CGFloat(descriptor.frame.width) * scale, accuracy: 0.0001)
            XCTAssertEqual(shellSurface.frame.height, CGFloat(descriptor.frame.height) * scale, accuracy: 0.0001)
            XCTAssertEqual(shellSurface.contentFrame.minX, shellSurface.frame.minX, accuracy: 0.0001)
            XCTAssertEqual(shellSurface.contentFrame.minY, shellSurface.frame.minY + style.headerHeight, accuracy: 0.0001)
            XCTAssertEqual(portalFrame.minX, canvasWindowFrame.minX + shellSurface.contentFrame.minX, accuracy: 0.0001)
            XCTAssertEqual(portalFrame.minY, canvasWindowFrame.maxY - shellSurface.contentFrame.maxY, accuracy: 0.0001)
            XCTAssertEqual(portalFrame.width, shellSurface.contentFrame.width, accuracy: 0.0001)
            XCTAssertEqual(portalFrame.height, shellSurface.contentFrame.height, accuracy: 0.0001)
        }
    }

    func testTrackpadPanViewportDrivesShellAndPortalFramesFromSameTransform() throws {
        let id = LayoutItemID(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000456")))
        let descriptor = CanvasSurfaceDescriptor(
            id: id,
            kind: .browser,
            frame: PixelRect(x: 320, y: 180, width: 500, height: 360),
            isFocused: true,
            renderMode: .nativeOverlay
        )
        let viewportSize = CGSize(width: 1_200, height: 800)
        let canvasWindowFrame = CGRect(x: 80, y: 120, width: 1_200, height: 800)
        let style = CanvasShellStyle(headerHeight: 20)
        var camera = CanvasCamera(
            viewport: CanvasViewport(
                visibleRect: PixelRect(x: 0, y: 0, width: 1_200, height: 800),
                scale: 1
            ),
            viewportSize: viewportSize
        )

        for delta in [
            CGSize(width: 80, height: -40),
            CGSize(width: -140, height: 60),
            CGSize(width: 240, height: 120),
        ] {
            camera = CanvasPresentationEngine.camera(
                byApplying: .pan(screenDelta: delta),
                to: camera
            )
            let scene = CanvasScene(
                viewport: camera.viewport,
                viewportSize: viewportSize,
                scale: CGFloat(camera.scale),
                surfaces: [descriptor]
            )
            let shellSurface = try XCTUnwrap(CanvasShellRenderPlan(scene: scene, style: style).surfaces.first)
            let portalFrame = try XCTUnwrap(CanvasWindowCoordinateMapper.windowFrame(
                forCanvasRect: shellSurface.contentFrame,
                inCanvasWindowFrame: canvasWindowFrame
            ))

            XCTAssertEqual(portalFrame.minX, canvasWindowFrame.minX + shellSurface.contentFrame.minX, accuracy: 0.0001)
            XCTAssertEqual(portalFrame.minY, canvasWindowFrame.maxY - shellSurface.contentFrame.maxY, accuracy: 0.0001)
            XCTAssertEqual(portalFrame.width, shellSurface.contentFrame.width, accuracy: 0.0001)
            XCTAssertEqual(portalFrame.height, shellSurface.contentFrame.height, accuracy: 0.0001)
        }
    }

    func testFastTrackpadPanSequenceKeepsShellPortalAndPresentationFramesInLockstep() throws {
        let terminalID = LayoutItemID(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000501")))
        let browserID = LayoutItemID(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000502")))
        let viewportSize = CGSize(width: 1_200, height: 800)
        let canvasWindowFrame = CGRect(x: 80, y: 120, width: viewportSize.width, height: viewportSize.height)
        let style = CanvasShellStyle(headerHeight: 20)
        let itemIDs = Set([terminalID, browserID])
        var document = CanvasDocument(
            policy: .freeform,
            viewport: CanvasViewport(visibleRect: PixelRect(x: 0, y: 0, width: 1_200, height: 800), scale: 1),
            items: [
                CanvasItem(
                    id: terminalID,
                    content: .pane(PaneID()),
                    frame: PixelRect(x: 120, y: 160, width: 540, height: 360),
                    zIndex: 2,
                    isNativeResolution: true
                ),
                CanvasItem(
                    id: browserID,
                    content: .surface(SurfaceID()),
                    frame: PixelRect(x: 720, y: 220, width: 560, height: 380),
                    zIndex: 3,
                    isNativeResolution: true
                ),
            ]
        )
        var camera = CanvasCamera(viewport: document.viewport, viewportSize: viewportSize)

        for delta in [
            CGSize(width: 18, height: -12),
            CGSize(width: 36, height: -24),
            CGSize(width: -54, height: 28),
            CGSize(width: 72, height: 48),
            CGSize(width: -90, height: -32),
        ] {
            camera = CanvasPresentationEngine.camera(byApplying: .pan(screenDelta: delta), to: camera)
            document.viewport = camera.viewport
            let presentation = CanvasPresentationEngine.presentation(
                document: document,
                viewportSize: viewportSize,
                focusedItemID: terminalID,
                activeItemID: terminalID,
                contentKinds: [terminalID: .terminal, browserID: .browser],
                interactionPhase: .panning,
                configuration: CanvasPresentationConfiguration(
                    headerHeight: style.headerHeight,
                    nativeOverlayConfiguration: CanvasNativeOverlayConfiguration(activeSurfaceID: terminalID),
                    overscanScreenPoints: 400
                )
            )
            let scene = CanvasScene(presentation: presentation)
            let plan = CanvasShellRenderPlan(scene: scene, style: style)
            let shellByID = Dictionary(uniqueKeysWithValues: plan.surfaces.map { ($0.id, $0) })

            XCTAssertTrue(presentation.usesUnifiedTexturePresentation)
            XCTAssertTrue(presentation.nativeOverlays.isEmpty)
            XCTAssertEqual(Set(presentation.textureSurfaces.map(\.id)), itemIDs)

            for itemID in itemIDs {
                let surface = try XCTUnwrap(presentation.presentationsByID[itemID])
                let shellSurface = try XCTUnwrap(shellByID[itemID])
                let portalFrame = try XCTUnwrap(CanvasWindowCoordinateMapper.windowFrame(
                    forCanvasRect: shellSurface.contentFrame,
                    inCanvasWindowFrame: canvasWindowFrame
                ))

                assertRectEqual(shellSurface.frame, surface.frameInCanvas)
                assertRectEqual(shellSurface.contentFrame, surface.contentFrameInCanvas)
                XCTAssertEqual(portalFrame.minX, canvasWindowFrame.minX + surface.contentFrameInCanvas.minX, accuracy: 0.0001)
                XCTAssertEqual(portalFrame.minY, canvasWindowFrame.maxY - surface.contentFrameInCanvas.maxY, accuracy: 0.0001)
                XCTAssertEqual(portalFrame.width, surface.contentFrameInCanvas.width, accuracy: 0.0001)
                XCTAssertEqual(portalFrame.height, surface.contentFrameInCanvas.height, accuracy: 0.0001)
            }
        }
    }

    func testTrackpadPanSettleRemountsNativeOverlayAtLastTextureFrame() throws {
        let activeID = LayoutItemID(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000503")))
        let viewportSize = CGSize(width: 1_200, height: 800)
        var document = CanvasDocument(
            policy: .freeform,
            viewport: CanvasViewport(visibleRect: PixelRect(x: 0, y: 0, width: 1_200, height: 800), scale: 1),
            items: [
                CanvasItem(
                    id: activeID,
                    content: .pane(PaneID()),
                    frame: PixelRect(x: 240, y: 180, width: 620, height: 420),
                    zIndex: 4,
                    isNativeResolution: true
                ),
            ]
        )
        var camera = CanvasCamera(viewport: document.viewport, viewportSize: viewportSize)
        for delta in [
            CGSize(width: 48, height: -24),
            CGSize(width: 72, height: -36),
            CGSize(width: -30, height: 18),
        ] {
            camera = CanvasPresentationEngine.camera(byApplying: .pan(screenDelta: delta), to: camera)
        }
        document.viewport = camera.viewport

        let moving = CanvasPresentationEngine.presentation(
            document: document,
            viewportSize: viewportSize,
            focusedItemID: activeID,
            activeItemID: activeID,
            contentKinds: [activeID: .terminal],
            interactionPhase: .panning,
            configuration: CanvasPresentationConfiguration(
                headerHeight: 20,
                nativeOverlayConfiguration: CanvasNativeOverlayConfiguration(activeSurfaceID: activeID),
                overscanScreenPoints: 0
            )
        )
        let settled = CanvasPresentationEngine.presentation(
            document: document,
            viewportSize: viewportSize,
            focusedItemID: activeID,
            activeItemID: activeID,
            contentKinds: [activeID: .terminal],
            interactionPhase: .idle,
            configuration: CanvasPresentationConfiguration(
                headerHeight: 20,
                nativeOverlayConfiguration: CanvasNativeOverlayConfiguration(activeSurfaceID: activeID),
                overscanScreenPoints: 0
            )
        )

        let movingSurface = try XCTUnwrap(moving.presentationsByID[activeID])
        let settledOverlay = try XCTUnwrap(settled.nativeOverlays.first)

        XCTAssertTrue(moving.usesUnifiedTexturePresentation)
        XCTAssertTrue(moving.nativeOverlays.isEmpty)
        XCTAssertEqual(moving.textureSurfaces.map(\.id), [activeID])
        XCTAssertFalse(settled.usesUnifiedTexturePresentation)
        XCTAssertEqual(settled.nativeOverlays.map(\.id), [activeID])
        assertRectEqual(settledOverlay.contentFrameInCanvas, movingSurface.contentFrameInCanvas)
        XCTAssertEqual(settledOverlay.nativeContentSize, movingSurface.nativeContentSize)
        XCTAssertEqual(settledOverlay.scale, movingSurface.presentationScale, accuracy: 0.0001)
    }

    func testWindowCoordinateMapperUsesCanvasTopLeftCoordinates() throws {
        let frame = try XCTUnwrap(CanvasWindowCoordinateMapper.windowFrame(
            forCanvasRect: CGRect(x: 40, y: 20, width: 320, height: 180),
            inCanvasWindowFrame: CGRect(x: 100, y: 200, width: 1_000, height: 800)
        ))

        XCTAssertEqual(frame, CGRect(x: 140, y: 800, width: 320, height: 180))
    }

    private func assertRectEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        accuracy: CGFloat = 0.0001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: accuracy, file: file, line: line)
    }
}
