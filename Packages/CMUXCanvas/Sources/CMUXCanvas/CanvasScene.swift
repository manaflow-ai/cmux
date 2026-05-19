import CMUXLayout
import CoreGraphics
import Foundation

public enum CanvasSurfaceKind: String, Codable, Sendable {
    case terminal
    case browser
    case generic
}

public enum CanvasSurfaceRenderMode: String, Codable, Sendable {
    case liveTexture
    case snapshotTexture
    case nativeOverlay
    case placeholder
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

public struct CanvasScene: Sendable, Equatable {
    public var viewport: CanvasViewport
    public var viewportSize: CGSize
    public var scale: CGFloat
    public var padding: CGFloat
    public var grid: CanvasGrid
    public var surfaces: [CanvasSurfaceDescriptor]
    public var alignmentGuides: [CanvasAlignmentGuide]

    public init(
        viewport: CanvasViewport = .native,
        viewportSize: CGSize = CGSize(width: 1, height: 1),
        scale: CGFloat? = nil,
        padding: CGFloat = 0,
        grid: CanvasGrid = .freeformDefault,
        surfaces: [CanvasSurfaceDescriptor] = [],
        alignmentGuides: [CanvasAlignmentGuide] = []
    ) {
        let resolvedScale = CGFloat(scale ?? CGFloat(CanvasViewportZoom.presentationScale(for: viewport)))
        self.viewport = viewport
        self.viewportSize = CGSize(
            width: max(1, viewportSize.width.isFinite ? viewportSize.width : 1),
            height: max(1, viewportSize.height.isFinite ? viewportSize.height : 1)
        )
        self.scale = max(0.0001, resolvedScale.isFinite ? resolvedScale : 1)
        self.padding = max(0, padding.isFinite ? padding : 0)
        self.grid = grid
        self.surfaces = surfaces.sorted(by: Self.surfaceSort)
        self.alignmentGuides = alignmentGuides
    }

    public var documentBounds: CGRect {
        CanvasGeometryEngine.visibleDocumentRect(
            viewport: viewport,
            viewportSize: viewportSize,
            scale: scale
        )
    }

    public var transform: CanvasTransform {
        CanvasTransform(
            documentBounds: documentBounds,
            scale: scale,
            padding: padding,
            documentOrigin: CGPoint(
                x: CGFloat(viewport.visibleRect.x),
                y: CGFloat(viewport.visibleRect.y)
            )
        )
    }

    public var visibleSurfaces: [CanvasSurfaceDescriptor] {
        let visibleDocumentRect = documentBounds
        return surfaces.filter { surface in
            surface.frame.cgRect.intersects(visibleDocumentRect)
        }
    }

    public func surfaceScreenFrame(for surface: CanvasSurfaceDescriptor) -> CGRect {
        transform.canvasRect(forDocumentFrame: surface.frame)
    }

    private static func surfaceSort(_ lhs: CanvasSurfaceDescriptor, _ rhs: CanvasSurfaceDescriptor) -> Bool {
        if lhs.zIndex != rhs.zIndex {
            return lhs.zIndex < rhs.zIndex
        }
        return lhs.id.description < rhs.id.description
    }
}

private extension PixelRect {
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
