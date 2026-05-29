import CMUXLayout
import CoreGraphics
import Foundation

public struct CanvasScene: Sendable, Equatable {
    public var viewport: CanvasViewport
    public var viewportSize: CGSize
    public var scale: CGFloat
    public var padding: CGFloat
    public var minimumSurfaceDisplaySize: CGSize
    public var grid: CanvasGrid
    public var surfaces: [CanvasSurfaceDescriptor]
    public var alignmentGuides: [CanvasAlignmentGuide]
    public var cullsSurfacesToViewport: Bool

    public init(
        viewport: CanvasViewport = .native,
        viewportSize: CGSize = CGSize(width: 1, height: 1),
        scale: CGFloat? = nil,
        padding: CGFloat = 0,
        minimumSurfaceDisplaySize: CGSize = .zero,
        grid: CanvasGrid = .freeformDefault,
        surfaces: [CanvasSurfaceDescriptor] = [],
        alignmentGuides: [CanvasAlignmentGuide] = [],
        cullsSurfacesToViewport: Bool = true
    ) {
        let resolvedScale = CGFloat(scale ?? CGFloat(CanvasViewportZoom.presentationScale(for: viewport)))
        self.viewport = viewport
        self.viewportSize = CGSize(
            width: max(1, viewportSize.width.isFinite ? viewportSize.width : 1),
            height: max(1, viewportSize.height.isFinite ? viewportSize.height : 1)
        )
        self.scale = max(0.0001, resolvedScale.isFinite ? resolvedScale : 1)
        self.padding = max(0, padding.isFinite ? padding : 0)
        self.minimumSurfaceDisplaySize = CGSize(
            width: max(0, minimumSurfaceDisplaySize.width.isFinite ? minimumSurfaceDisplaySize.width : 0),
            height: max(0, minimumSurfaceDisplaySize.height.isFinite ? minimumSurfaceDisplaySize.height : 0)
        )
        self.grid = grid
        self.surfaces = surfaces.sorted(by: Self.surfaceSort)
        self.alignmentGuides = alignmentGuides
        self.cullsSurfacesToViewport = cullsSurfacesToViewport
    }

    public init(
        presentation: CanvasPresentationState,
        padding: CGFloat? = nil
    ) {
        self.init(
            viewport: presentation.viewport,
            viewportSize: presentation.viewportSize,
            scale: presentation.scale,
            padding: padding ?? presentation.padding,
            minimumSurfaceDisplaySize: presentation.minimumSurfaceDisplaySize,
            grid: presentation.grid,
            surfaces: presentation.surfaces,
            alignmentGuides: presentation.alignmentGuides,
            cullsSurfacesToViewport: false
        )
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
        guard cullsSurfacesToViewport else {
            return surfaces
        }
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
        if lhs.isFocused != rhs.isFocused {
            return !lhs.isFocused && rhs.isFocused
        }
        return lhs.id.description < rhs.id.description
    }
}
