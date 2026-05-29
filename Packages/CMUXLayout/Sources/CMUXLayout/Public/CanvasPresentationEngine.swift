import CoreGraphics
import Foundation

public enum CanvasPlacementPolicy: String, Codable, Sendable, Equatable {
    case freeform
    case scrollingColumns

    public init(_ policy: CanvasLayoutPolicy) {
        switch policy {
        case .freeform:
            self = .freeform
        case .scrollingColumns:
            self = .scrollingColumns
        }
    }

    public var canvasLayoutPolicy: CanvasLayoutPolicy {
        switch self {
        case .freeform:
            return .freeform
        case .scrollingColumns:
            return .scrollingColumns
        }
    }
}

public struct CanvasCamera: Codable, Sendable, Equatable {
    public static let minimumScale = CanvasViewportZoom.minimumScale
    public static let maximumScale = CanvasViewportZoom.maximumScale

    public var origin: CGPoint
    public var scale: Double
    public var viewportSize: CGSize

    public init(
        origin: CGPoint = .zero,
        scale: Double = CanvasViewportZoom.maximumScale,
        viewportSize: CGSize = CGSize(width: 1_200, height: 800)
    ) {
        self.origin = CGPoint(
            x: origin.x.isFinite ? origin.x : 0,
            y: origin.y.isFinite ? origin.y : 0
        )
        self.scale = CanvasViewportZoom.clampedScale(scale)
        self.viewportSize = CGSize(
            width: max(1, viewportSize.width.isFinite ? viewportSize.width : 1),
            height: max(1, viewportSize.height.isFinite ? viewportSize.height : 1)
        )
    }

    public init(viewport: CanvasViewport, viewportSize: CGSize) {
        self.init(
            origin: CGPoint(x: viewport.visibleRect.x, y: viewport.visibleRect.y),
            scale: viewport.scale,
            viewportSize: viewportSize
        )
    }

    public var viewport: CanvasViewport {
        CanvasViewport(
            visibleRect: PixelRect(
                x: Double(origin.x),
                y: Double(origin.y),
                width: max(1, Double(viewportSize.width) / scale),
                height: max(1, Double(viewportSize.height) / scale)
            ),
            scale: scale
        )
    }

    public var visibleDocumentRect: CGRect {
        CGRect(
            x: origin.x,
            y: origin.y,
            width: max(1, viewportSize.width / CGFloat(scale)),
            height: max(1, viewportSize.height / CGFloat(scale))
        )
    }

    public var transform: CanvasTransform {
        CanvasTransform(
            documentBounds: visibleDocumentRect,
            scale: CGFloat(scale),
            padding: 0,
            documentOrigin: origin
        )
    }

    public func documentPoint(forScreenPoint point: CGPoint) -> CGPoint {
        transform.documentPoint(forCanvasPoint: point)
    }

    public func screenPoint(forDocumentPoint point: CGPoint) -> CGPoint {
        transform.canvasPoint(forDocumentPoint: point)
    }

    public func screenRect(forDocumentFrame frame: PixelRect) -> CGRect {
        transform.canvasRect(forDocumentFrame: frame)
    }

    public func documentRect(forScreenRect rect: CGRect) -> CGRect {
        let start = documentPoint(forScreenPoint: rect.origin)
        let end = documentPoint(forScreenPoint: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(
            x: start.x,
            y: start.y,
            width: max(1, end.x - start.x),
            height: max(1, end.y - start.y)
        )
    }

    public func panned(screenDelta: CGSize) -> CanvasCamera {
        let safeScale = max(0.0001, CGFloat(scale))
        return CanvasCamera(
            origin: CGPoint(
                x: origin.x - ((screenDelta.width.isFinite ? screenDelta.width : 0) / safeScale),
                y: origin.y - ((screenDelta.height.isFinite ? screenDelta.height : 0) / safeScale)
            ),
            scale: scale,
            viewportSize: viewportSize
        )
    }

    public func zoomed(to nextScale: Double, anchorScreenPoint: CGPoint?) -> CanvasCamera {
        let oldScale = max(0.0001, CGFloat(scale))
        let resolvedScale = CanvasViewportZoom.clampedScale(nextScale)
        let newScale = max(0.0001, CGFloat(resolvedScale))
        let anchor = anchorScreenPoint ?? CGPoint(
            x: max(1, viewportSize.width) / 2,
            y: max(1, viewportSize.height) / 2
        )
        let documentAnchor = CGPoint(
            x: origin.x + (anchor.x / oldScale),
            y: origin.y + (anchor.y / oldScale)
        )
        return CanvasCamera(
            origin: CGPoint(
                x: documentAnchor.x - (anchor.x / newScale),
                y: documentAnchor.y - (anchor.y / newScale)
            ),
            scale: resolvedScale,
            viewportSize: viewportSize
        )
    }

    public func resizedViewport(to viewportSize: CGSize) -> CanvasCamera {
        CanvasCamera(origin: origin, scale: scale, viewportSize: viewportSize)
    }

    public func revealing(
        frame: PixelRect,
        padding: CGFloat = 80,
        preferredScale: Double? = nil
    ) -> CanvasCamera {
        let targetScale = preferredScale.map(CanvasViewportZoom.clampedScale) ?? scale
        let safeScale = max(0.0001, CGFloat(targetScale))
        let visibleWidth = max(1, viewportSize.width / safeScale)
        let visibleHeight = max(1, viewportSize.height / safeScale)
        let paddingInDocument = max(0, padding / safeScale)
        let itemRect = frame.cgRect.insetBy(dx: -paddingInDocument, dy: -paddingInDocument)

        var nextOrigin = origin
        if itemRect.minX < nextOrigin.x {
            nextOrigin.x = itemRect.minX
        } else if itemRect.maxX > nextOrigin.x + visibleWidth {
            nextOrigin.x = itemRect.maxX - visibleWidth
        }

        if itemRect.minY < nextOrigin.y {
            nextOrigin.y = itemRect.minY
        } else if itemRect.maxY > nextOrigin.y + visibleHeight {
            nextOrigin.y = itemRect.maxY - visibleHeight
        }

        return CanvasCamera(origin: nextOrigin, scale: targetScale, viewportSize: viewportSize)
    }
}

public enum CanvasViewportCommand: Sendable, Equatable {
    case setViewport(CanvasViewport)
    case setCamera(CanvasCamera)
    case resizeViewport(CGSize)
    case pan(screenDelta: CGSize)
    case zoom(scale: Double, anchorScreenPoint: CGPoint?)
    case wheelZoom(deltaY: Double, anchorScreenPoint: CGPoint?)
    case magnify(Double, anchorScreenPoint: CGPoint?)
    case smartZoom(anchorScreenPoint: CGPoint?)
    case reveal(frame: PixelRect, padding: CGFloat, preferredScale: Double?)
}

public enum CanvasInteractionPhase: String, Sendable, Equatable {
    case idle
    case panning
    case zooming
    case draggingSurface
    case resizingSurface
}

public enum CanvasPresentationInteractionResolver {
    public static func phase(
        cameraPhase: CanvasInteractionPhase,
        isViewportAnimating: Bool,
        hasParkedNativeSurfacesForCamera: Bool = false,
        hasActiveDrag: Bool = false,
        hasActiveResize: Bool = false
    ) -> CanvasInteractionPhase {
        if hasActiveResize {
            return .resizingSurface
        }
        if hasActiveDrag {
            return .draggingSurface
        }
        if hasParkedNativeSurfacesForCamera {
            return cameraPhase == .zooming ? .zooming : .panning
        }
        if isViewportAnimating {
            return cameraPhase == .idle ? .panning : cameraPhase
        }
        return cameraPhase
    }
}

public enum CanvasSurfaceKind: String, Codable, Sendable, Equatable {
    case terminal
    case browser
    case generic
}

public enum CanvasSurfaceRenderMode: String, Codable, Sendable, Equatable {
    case liveTexture
    case snapshotTexture
    case nativeOverlay
    case placeholder
}

public enum CanvasNativeSurfaceParkingMode: String, Codable, Sendable, Equatable {
    case unmount
    case freezeInPlace
}

public enum CanvasNativeSurfaceParkingPolicy {
    public static func mode(
        usesUnifiedTexturePresentation: Bool,
        hasParkedNativeSurfacesForCamera: Bool
    ) -> CanvasNativeSurfaceParkingMode {
        if usesUnifiedTexturePresentation || hasParkedNativeSurfacesForCamera {
            return .freezeInPlace
        }
        return .unmount
    }

    public static func parkingFrame(
        preserving frame: CGRect,
        offset: CGFloat = 100_000
    ) -> CGRect {
        let width = frame.size.width.isFinite && frame.size.width > 0 ? frame.size.width : 1
        let height = frame.size.height.isFinite && frame.size.height > 0 ? frame.size.height : 1
        let resolvedOffset = max(1, offset.isFinite ? offset : 100_000)
        return CGRect(
            x: -resolvedOffset - width,
            y: -resolvedOffset - height,
            width: width,
            height: height
        )
    }
}

public struct CanvasSurfaceDescriptor: Identifiable, Codable, Sendable, Equatable {
    public var id: LayoutItemID
    public var kind: CanvasSurfaceKind
    public var frame: PixelRect
    public var zIndex: Int
    public var isFocused: Bool
    public var renderMode: CanvasSurfaceRenderMode

    public init(
        id: LayoutItemID,
        kind: CanvasSurfaceKind,
        frame: PixelRect,
        zIndex: Int = 0,
        isFocused: Bool = false,
        renderMode: CanvasSurfaceRenderMode = .nativeOverlay
    ) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.zIndex = zIndex
        self.isFocused = isFocused
        self.renderMode = renderMode
    }
}

public struct CanvasNativeOverlayConfiguration: Sendable, Equatable {
    public var minimumNativeScale: CGFloat
    public var activeSurfaceID: LayoutItemID?

    public init(
        minimumNativeScale: CGFloat = CGFloat(CanvasViewportZoom.nativeOverlayMinimumScale),
        activeSurfaceID: LayoutItemID? = nil
    ) {
        self.minimumNativeScale = max(
            0.0001,
            minimumNativeScale.isFinite
                ? minimumNativeScale
                : CGFloat(CanvasViewportZoom.nativeOverlayMinimumScale)
        )
        self.activeSurfaceID = activeSurfaceID
    }
}

public struct CanvasNativeOverlay: Identifiable, Sendable, Equatable {
    public var id: LayoutItemID
    public var kind: CanvasSurfaceKind
    public var frameInCanvas: CGRect
    public var contentFrameInCanvas: CGRect
    public var nativeContentSize: CGSize
    public var zIndex: Int
    public var scale: CGFloat

    public init(
        id: LayoutItemID,
        kind: CanvasSurfaceKind,
        frameInCanvas: CGRect,
        contentFrameInCanvas: CGRect,
        nativeContentSize: CGSize,
        zIndex: Int,
        scale: CGFloat
    ) {
        self.id = id
        self.kind = kind
        self.frameInCanvas = frameInCanvas.standardized
        self.contentFrameInCanvas = contentFrameInCanvas.standardized
        self.nativeContentSize = CGSize(
            width: max(1, nativeContentSize.width),
            height: max(1, nativeContentSize.height)
        )
        self.zIndex = zIndex
        self.scale = max(0.0001, scale)
    }

    public var frameInWindow: CGRect {
        frameInCanvas
    }

    public func presentation(frameInWindow: CGRect? = nil) -> CanvasSurfacePresentation {
        CanvasSurfacePresentation(
            frameInWindow: frameInWindow ?? contentFrameInCanvas,
            nativeContentSize: nativeContentSize,
            scale: scale
        )
    }
}

public enum CanvasScrollPassthroughPolicy {
    public static func frames(nativeOverlays: [CanvasNativeOverlay]) -> [CGRect] {
        []
    }
}

public struct CanvasNativeOverlayPlan: Sendable, Equatable {
    public var nativeOverlays: [CanvasNativeOverlay]
    public var textureSurfaces: [CanvasSurfaceDescriptor]

    public init(nativeOverlays: [CanvasNativeOverlay], textureSurfaces: [CanvasSurfaceDescriptor]) {
        self.nativeOverlays = nativeOverlays
        self.textureSurfaces = textureSurfaces
    }
}

public struct CanvasPresentationConfiguration: Sendable, Equatable {
    public var grid: CanvasGrid
    public var padding: CGFloat
    public var headerHeight: CGFloat
    public var minimumSurfaceDisplaySize: CGSize
    public var nativeOverlayConfiguration: CanvasNativeOverlayConfiguration
    public var overscanScreenPoints: CGFloat

    public init(
        grid: CanvasGrid = .freeformDefault,
        padding: CGFloat = 0,
        headerHeight: CGFloat = 20,
        minimumSurfaceDisplaySize: CGSize = CGSize(width: 240, height: 170),
        nativeOverlayConfiguration: CanvasNativeOverlayConfiguration = CanvasNativeOverlayConfiguration(),
        overscanScreenPoints: CGFloat = 160
    ) {
        self.grid = grid
        self.padding = max(0, padding.isFinite ? padding : 0)
        self.headerHeight = max(0, headerHeight.isFinite ? headerHeight : 20)
        self.minimumSurfaceDisplaySize = CGSize(
            width: max(1, minimumSurfaceDisplaySize.width.isFinite ? minimumSurfaceDisplaySize.width : 1),
            height: max(1, minimumSurfaceDisplaySize.height.isFinite ? minimumSurfaceDisplaySize.height : 1)
        )
        self.nativeOverlayConfiguration = nativeOverlayConfiguration
        self.overscanScreenPoints = max(0, overscanScreenPoints.isFinite ? overscanScreenPoints : 0)
    }
}

public struct CanvasPresentationSurface: Identifiable, Sendable, Equatable {
    public var id: LayoutItemID
    public var item: CanvasItem
    public var kind: CanvasSurfaceKind
    public var descriptor: CanvasSurfaceDescriptor
    public var frameInCanvas: CGRect
    public var contentFrameInCanvas: CGRect
    public var nativeContentSize: CGSize
    public var presentationScale: CGFloat

    public init(
        id: LayoutItemID,
        item: CanvasItem,
        kind: CanvasSurfaceKind,
        descriptor: CanvasSurfaceDescriptor,
        frameInCanvas: CGRect,
        contentFrameInCanvas: CGRect,
        nativeContentSize: CGSize,
        presentationScale: CGFloat
    ) {
        self.id = id
        self.item = item
        self.kind = kind
        self.descriptor = descriptor
        self.frameInCanvas = frameInCanvas.standardized
        self.contentFrameInCanvas = contentFrameInCanvas.standardized
        self.nativeContentSize = CGSize(
            width: max(1, nativeContentSize.width),
            height: max(1, nativeContentSize.height)
        )
        self.presentationScale = max(0.0001, presentationScale)
    }
}

public struct CanvasPresentationState: Sendable, Equatable {
    public var document: CanvasDocument
    public var camera: CanvasCamera
    public var viewport: CanvasViewport
    public var viewportSize: CGSize
    public var scale: CGFloat
    public var grid: CanvasGrid
    public var padding: CGFloat
    public var minimumSurfaceDisplaySize: CGSize
    public var focusedItemID: LayoutItemID?
    public var activeItemID: LayoutItemID?
    public var interactionPhase: CanvasInteractionPhase
    public var visibleItems: [CanvasItem]
    public var surfaces: [CanvasSurfaceDescriptor]
    public var presentationSurfaces: [CanvasPresentationSurface]
    public var nativeOverlays: [CanvasNativeOverlay]
    public var textureSurfaces: [CanvasSurfaceDescriptor]
    public var alignmentGuides: [CanvasAlignmentGuide]

    public init(
        document: CanvasDocument,
        camera: CanvasCamera,
        viewport: CanvasViewport,
        viewportSize: CGSize,
        scale: CGFloat,
        grid: CanvasGrid,
        padding: CGFloat,
        minimumSurfaceDisplaySize: CGSize,
        focusedItemID: LayoutItemID?,
        activeItemID: LayoutItemID?,
        interactionPhase: CanvasInteractionPhase,
        visibleItems: [CanvasItem],
        surfaces: [CanvasSurfaceDescriptor],
        presentationSurfaces: [CanvasPresentationSurface],
        nativeOverlays: [CanvasNativeOverlay],
        textureSurfaces: [CanvasSurfaceDescriptor],
        alignmentGuides: [CanvasAlignmentGuide]
    ) {
        self.document = document
        self.camera = camera
        self.viewport = viewport
        self.viewportSize = viewportSize
        self.scale = scale
        self.grid = grid
        self.padding = padding
        self.minimumSurfaceDisplaySize = minimumSurfaceDisplaySize
        self.focusedItemID = focusedItemID
        self.activeItemID = activeItemID
        self.interactionPhase = interactionPhase
        self.visibleItems = visibleItems
        self.surfaces = surfaces
        self.presentationSurfaces = presentationSurfaces
        self.nativeOverlays = nativeOverlays
        self.textureSurfaces = textureSurfaces
        self.alignmentGuides = alignmentGuides
    }

    public var presentationsByID: [LayoutItemID: CanvasPresentationSurface] {
        Dictionary(uniqueKeysWithValues: presentationSurfaces.map { ($0.id, $0) })
    }

    public var nativeOverlaysByID: [LayoutItemID: CanvasNativeOverlay] {
        Dictionary(uniqueKeysWithValues: nativeOverlays.map { ($0.id, $0) })
    }

    public var usesUnifiedTexturePresentation: Bool {
        switch interactionPhase {
        case .zooming:
            return true
        case .panning:
            return nativeOverlays.isEmpty
        case .idle, .draggingSurface, .resizingSurface:
            return false
        }
    }
}

public enum CanvasPresentationEngine {
    public static func camera(
        byApplying command: CanvasViewportCommand,
        to camera: CanvasCamera
    ) -> CanvasCamera {
        switch command {
        case .setViewport(let viewport):
            return CanvasCamera(viewport: viewport, viewportSize: camera.viewportSize)
        case .setCamera(let next):
            return next
        case .resizeViewport(let viewportSize):
            return camera.resizedViewport(to: viewportSize)
        case .pan(let screenDelta):
            return camera.panned(screenDelta: screenDelta)
        case .zoom(let scale, let anchor):
            return camera.zoomed(to: scale, anchorScreenPoint: anchor)
        case .wheelZoom(let deltaY, let anchor):
            return camera.zoomed(
                to: CanvasViewportZoom.scaleAfterWheel(deltaY: deltaY, currentScale: camera.scale),
                anchorScreenPoint: anchor
            )
        case .magnify(let magnification, let anchor):
            return camera.zoomed(
                to: CanvasViewportZoom.scaleAfterMagnification(magnification, currentScale: camera.scale),
                anchorScreenPoint: anchor
            )
        case .smartZoom(let anchor):
            return camera.zoomed(
                to: CanvasViewportZoom.smartZoomScale(currentScale: camera.scale),
                anchorScreenPoint: anchor
            )
        case .reveal(let frame, let padding, let preferredScale):
            return camera.revealing(frame: frame, padding: padding, preferredScale: preferredScale)
        }
    }

    public static func presentation(
        document: CanvasDocument,
        viewportSize: CGSize,
        focusedItemID: LayoutItemID?,
        activeItemID: LayoutItemID?,
        contentKinds: [LayoutItemID: CanvasSurfaceKind] = [:],
        itemFrameOverrides: [LayoutItemID: PixelRect] = [:],
        alignmentGuides: [CanvasAlignmentGuide] = [],
        interactionPhase: CanvasInteractionPhase = .idle,
        configuration: CanvasPresentationConfiguration = CanvasPresentationConfiguration()
    ) -> CanvasPresentationState {
        let camera = CanvasCamera(viewport: document.viewport, viewportSize: viewportSize)
        return presentation(
            document: document,
            camera: camera,
            focusedItemID: focusedItemID,
            activeItemID: activeItemID,
            contentKinds: contentKinds,
            itemFrameOverrides: itemFrameOverrides,
            alignmentGuides: alignmentGuides,
            interactionPhase: interactionPhase,
            configuration: configuration
        )
    }

    public static func presentation(
        document: CanvasDocument,
        camera: CanvasCamera,
        focusedItemID: LayoutItemID?,
        activeItemID: LayoutItemID?,
        contentKinds: [LayoutItemID: CanvasSurfaceKind] = [:],
        itemFrameOverrides: [LayoutItemID: PixelRect] = [:],
        alignmentGuides: [CanvasAlignmentGuide] = [],
        interactionPhase: CanvasInteractionPhase = .idle,
        configuration: CanvasPresentationConfiguration = CanvasPresentationConfiguration()
    ) -> CanvasPresentationState {
        let viewport = camera.viewport
        let scale = CGFloat(camera.scale)
        let sortedItems = document.items
            .map { item -> CanvasItem in
                var item = item
                if let override = itemFrameOverrides[item.id] {
                    item.frame = override
                }
                return item
            }
            .sorted(by: itemSort)
        let visibleItems = CanvasGeometryEngine.visibleItems(
            sortedItems,
            viewport: viewport,
            viewportSize: camera.viewportSize,
            scale: scale,
            overscanScreenPoints: configuration.overscanScreenPoints
        )
        let resolvedActiveItemID = activeItemID ?? focusedItemID
        let descriptors = visibleItems.map { item in
            descriptor(
                for: item,
                focusedItemID: focusedItemID,
                activeItemID: resolvedActiveItemID,
                kind: contentKinds[item.id] ?? .generic,
                scale: scale,
                interactionPhase: interactionPhase,
                configuration: configuration
            )
        }.sorted(by: descriptorSort)
        let surfaces = visibleItems.map { item in
            let kind = contentKinds[item.id] ?? .generic
            let descriptor = descriptor(
                for: item,
                focusedItemID: focusedItemID,
                activeItemID: resolvedActiveItemID,
                kind: kind,
                scale: scale,
                interactionPhase: interactionPhase,
                configuration: configuration
            )
            let transform = CanvasTransform(
                documentBounds: camera.visibleDocumentRect,
                scale: scale,
                padding: configuration.padding,
                documentOrigin: camera.origin
            )
            let screenFrame = transform.canvasRect(forDocumentFrame: item.frame)
            let cardSize = CanvasGeometryEngine.cardSize(
                for: item.frame,
                scale: scale,
                minimumDisplaySize: configuration.minimumSurfaceDisplaySize
            )
            let frameInCanvas = CGRect(origin: screenFrame.origin, size: cardSize).standardized
            let headerHeight = min(configuration.headerHeight, max(0, frameInCanvas.height))
            let contentFrame = CGRect(
                x: frameInCanvas.minX,
                y: frameInCanvas.minY + headerHeight,
                width: frameInCanvas.width,
                height: max(1, frameInCanvas.height - headerHeight)
            )
            let nativeContentSize = nativeContentSize(
                for: item,
                visualContentSize: contentFrame.size
            )
            return CanvasPresentationSurface(
                id: item.id,
                item: item,
                kind: kind,
                descriptor: descriptor,
                frameInCanvas: frameInCanvas,
                contentFrameInCanvas: contentFrame,
                nativeContentSize: nativeContentSize,
                presentationScale: presentationScale(
                    for: item,
                    nativeContentSize: nativeContentSize,
                    visualContentSize: contentFrame.size
                )
            )
        }.sorted { lhs, rhs in
            descriptorSort(lhs.descriptor, rhs.descriptor)
        }

        let overlays = nativeOverlays(
            surfaces: surfaces,
            scale: scale,
            configuration: configuration.nativeOverlayConfiguration
        )
        let nativeIDs = Set(overlays.map(\.id))
        let textureSurfaces = descriptors
            .filter { !nativeIDs.contains($0.id) && $0.renderMode != .placeholder }

        return CanvasPresentationState(
            document: document,
            camera: camera,
            viewport: viewport,
            viewportSize: camera.viewportSize,
            scale: scale,
            grid: configuration.grid,
            padding: configuration.padding,
            minimumSurfaceDisplaySize: configuration.minimumSurfaceDisplaySize,
            focusedItemID: focusedItemID,
            activeItemID: resolvedActiveItemID,
            interactionPhase: interactionPhase,
            visibleItems: visibleItems,
            surfaces: descriptors,
            presentationSurfaces: surfaces,
            nativeOverlays: overlays,
            textureSurfaces: textureSurfaces,
            alignmentGuides: alignmentGuides
        )
    }

    private static func descriptor(
        for item: CanvasItem,
        focusedItemID: LayoutItemID?,
        activeItemID: LayoutItemID?,
        kind: CanvasSurfaceKind,
        scale: CGFloat,
        interactionPhase: CanvasInteractionPhase,
        configuration: CanvasPresentationConfiguration
    ) -> CanvasSurfaceDescriptor {
        let renderMode = renderMode(
            for: item,
            activeItemID: activeItemID,
            scale: scale,
            interactionPhase: interactionPhase,
            configuration: configuration.nativeOverlayConfiguration
        )
        return CanvasSurfaceDescriptor(
            id: item.id,
            kind: kind,
            frame: item.frame,
            zIndex: zIndex(
                for: item,
                renderMode: renderMode,
                focusedItemID: focusedItemID,
                activeItemID: activeItemID
            ),
            isFocused: item.id == focusedItemID,
            renderMode: renderMode
        )
    }

    private static func renderMode(
        for item: CanvasItem,
        activeItemID: LayoutItemID?,
        scale: CGFloat,
        interactionPhase: CanvasInteractionPhase,
        configuration: CanvasNativeOverlayConfiguration
    ) -> CanvasSurfaceRenderMode {
        guard isLiveMountable(item) else {
            return .snapshotTexture
        }
        switch interactionPhase {
        case .zooming:
            return .snapshotTexture
        case .panning:
            break
        case .idle, .draggingSurface, .resizingSurface:
            break
        }
        let nativeActiveID = configuration.activeSurfaceID ?? activeItemID
        guard item.id == nativeActiveID,
              scale >= configuration.minimumNativeScale else {
            return .snapshotTexture
        }
        return .nativeOverlay
    }

    private static func isLiveMountable(_ item: CanvasItem) -> Bool {
        switch item.content {
        case .pane, .surface:
            return true
        case .group:
            return false
        }
    }

    private static func nativeOverlays(
        surfaces: [CanvasPresentationSurface],
        scale: CGFloat,
        configuration: CanvasNativeOverlayConfiguration
    ) -> [CanvasNativeOverlay] {
        surfaces.compactMap { surface in
            guard surface.descriptor.renderMode == .nativeOverlay else { return nil }
            guard scale >= configuration.minimumNativeScale else { return nil }
            if let activeSurfaceID = configuration.activeSurfaceID,
               surface.id != activeSurfaceID {
                return nil
            }
            return CanvasNativeOverlay(
                id: surface.id,
                kind: surface.kind,
                frameInCanvas: surface.frameInCanvas,
                contentFrameInCanvas: surface.contentFrameInCanvas,
                nativeContentSize: surface.nativeContentSize,
                zIndex: surface.descriptor.zIndex,
                scale: surface.presentationScale
            )
        }.sorted { lhs, rhs in
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            return lhs.id.description < rhs.id.description
        }
    }

    private static func zIndex(
        for item: CanvasItem,
        renderMode: CanvasSurfaceRenderMode,
        focusedItemID: LayoutItemID?,
        activeItemID: LayoutItemID?
    ) -> Int {
        let isActive = item.id == activeItemID || item.id == focusedItemID
        if isActive {
            return item.zIndex + 20_000
        }
        if renderMode == .nativeOverlay {
            return item.zIndex + 10_000
        }
        return item.zIndex
    }

    private static func nativeContentSize(
        for item: CanvasItem,
        visualContentSize: CGSize
    ) -> CGSize {
        let visualSize = CGSize(
            width: max(1, visualContentSize.width),
            height: max(1, visualContentSize.height)
        )
        if item.isNativeResolution {
            return visualSize
        }
        return CGSize(
            width: max(1, CGFloat(item.frame.width)),
            height: max(1, CGFloat(item.frame.height))
        )
    }

    private static func presentationScale(
        for item: CanvasItem,
        nativeContentSize: CGSize,
        visualContentSize: CGSize
    ) -> CGFloat {
        if item.isNativeResolution {
            return 1
        }
        guard nativeContentSize.width > 0,
              nativeContentSize.height > 0,
              visualContentSize.width > 0,
              visualContentSize.height > 0 else {
            return 1
        }
        return max(
            0.0001,
            min(
                visualContentSize.width / nativeContentSize.width,
                visualContentSize.height / nativeContentSize.height
            )
        )
    }

    private static func itemSort(_ lhs: CanvasItem, _ rhs: CanvasItem) -> Bool {
        if lhs.zIndex != rhs.zIndex {
            return lhs.zIndex < rhs.zIndex
        }
        return lhs.id.description < rhs.id.description
    }

    private static func descriptorSort(_ lhs: CanvasSurfaceDescriptor, _ rhs: CanvasSurfaceDescriptor) -> Bool {
        if lhs.zIndex != rhs.zIndex {
            return lhs.zIndex < rhs.zIndex
        }
        if lhs.isFocused != rhs.isFocused {
            return !lhs.isFocused && rhs.isFocused
        }
        return lhs.id.description < rhs.id.description
    }
}

public struct CanvasViewportAnimation: Sendable, Equatable {
    public var startViewport: CanvasViewport
    public var targetViewport: CanvasViewport
    public var startTime: TimeInterval
    public var duration: TimeInterval

    public init(
        startViewport: CanvasViewport,
        targetViewport: CanvasViewport,
        startTime: TimeInterval,
        duration: TimeInterval = 0.18
    ) {
        self.startViewport = startViewport
        self.targetViewport = targetViewport
        self.startTime = startTime.isFinite ? startTime : 0
        self.duration = max(0.001, duration.isFinite ? duration : 0.18)
    }

    public func progress(at time: TimeInterval) -> Double {
        let elapsed = max(0, (time.isFinite ? time : startTime) - startTime)
        return min(1, elapsed / duration)
    }

    public func easedProgress(at time: TimeInterval) -> Double {
        Self.easeOutCubic(progress(at: time))
    }

    public func viewport(at time: TimeInterval) -> CanvasViewport {
        viewport(progress: easedProgress(at: time))
    }

    public func isComplete(at time: TimeInterval) -> Bool {
        progress(at: time) >= 1
    }

    public func viewport(progress: Double) -> CanvasViewport {
        let t = min(max(progress.isFinite ? progress : 1, 0), 1)
        return CanvasViewport(
            visibleRect: PixelRect(
                x: Self.lerp(startViewport.visibleRect.x, targetViewport.visibleRect.x, t),
                y: Self.lerp(startViewport.visibleRect.y, targetViewport.visibleRect.y, t),
                width: Self.lerp(startViewport.visibleRect.width, targetViewport.visibleRect.width, t),
                height: Self.lerp(startViewport.visibleRect.height, targetViewport.visibleRect.height, t)
            ),
            scale: Self.lerp(startViewport.scale, targetViewport.scale, t)
        )
    }

    public static func easeOutCubic(_ progress: Double) -> Double {
        let t = min(max(progress.isFinite ? progress : 1, 0), 1)
        let inverse = 1 - t
        return 1 - (inverse * inverse * inverse)
    }

    private static func lerp(_ start: Double, _ end: Double, _ progress: Double) -> Double {
        start + ((end - start) * progress)
    }
}

public struct CanvasViewportPresentationState: Sendable, Equatable {
    public private(set) var presentedViewport: CanvasViewport?
    public private(set) var stableViewport: CanvasViewport
    public private(set) var activeAnimation: CanvasViewportAnimation?

    public init(
        presentedViewport: CanvasViewport? = nil,
        stableViewport: CanvasViewport = .native,
        activeAnimation: CanvasViewportAnimation? = nil
    ) {
        self.presentedViewport = presentedViewport
        self.stableViewport = stableViewport
        self.activeAnimation = activeAnimation
    }

    public var isAnimating: Bool {
        activeAnimation != nil
    }

    public func displayedViewport(fallback: CanvasViewport) -> CanvasViewport {
        if let presentedViewport {
            return presentedViewport
        }
        if activeAnimation != nil {
            return stableViewport
        }
        return fallback
    }

    public mutating func startAnimation(
        to targetViewport: CanvasViewport,
        now: TimeInterval,
        duration: TimeInterval = 0.18
    ) -> Bool {
        let startViewport = presentedViewport ?? stableViewport
        guard startViewport != targetViewport else {
            stableViewport = targetViewport
            presentedViewport = nil
            activeAnimation = nil
            return false
        }

        activeAnimation = CanvasViewportAnimation(
            startViewport: startViewport,
            targetViewport: targetViewport,
            startTime: now,
            duration: duration
        )
        presentedViewport = startViewport
        return true
    }

    public mutating func tick(at time: TimeInterval) {
        guard let activeAnimation else { return }
        let viewport = activeAnimation.viewport(at: time)
        presentedViewport = viewport
        stableViewport = viewport

        if activeAnimation.isComplete(at: time) {
            presentedViewport = nil
            stableViewport = activeAnimation.targetViewport
            self.activeAnimation = nil
        }
    }

    public mutating func cancel(stableViewport: CanvasViewport) {
        activeAnimation = nil
        presentedViewport = nil
        self.stableViewport = stableViewport
    }
}

public enum CanvasWindowCoordinateMapper {
    public static func windowFrame(
        forCanvasRect canvasRect: CGRect,
        inCanvasWindowFrame canvasWindowFrame: CGRect
    ) -> CGRect? {
        let canvasRect = canvasRect.standardized
        let canvasWindowFrame = canvasWindowFrame.standardized
        guard canvasRect.origin.x.isFinite,
              canvasRect.origin.y.isFinite,
              canvasRect.size.width.isFinite,
              canvasRect.size.height.isFinite,
              canvasWindowFrame.origin.x.isFinite,
              canvasWindowFrame.origin.y.isFinite,
              canvasWindowFrame.size.width.isFinite,
              canvasWindowFrame.size.height.isFinite,
              canvasRect.width > 1,
              canvasRect.height > 1,
              canvasWindowFrame.width > 1,
              canvasWindowFrame.height > 1 else {
            return nil
        }

        return CGRect(
            x: canvasWindowFrame.minX + canvasRect.minX,
            y: canvasWindowFrame.maxY - canvasRect.maxY,
            width: canvasRect.width,
            height: canvasRect.height
        )
    }
}
