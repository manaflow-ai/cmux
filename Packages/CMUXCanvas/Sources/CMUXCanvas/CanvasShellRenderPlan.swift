import CMUXLayout
import CoreGraphics
import Foundation

public struct CanvasColor: Codable, Sendable, Equatable {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float

    public init(red: Float, green: Float, blue: Float, alpha: Float = 1) {
        self.red = Self.clamped(red)
        self.green = Self.clamped(green)
        self.blue = Self.clamped(blue)
        self.alpha = Self.clamped(alpha)
    }

    public func withAlpha(_ alpha: Float) -> CanvasColor {
        CanvasColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public func multiplyingAlpha(_ multiplier: Float) -> CanvasColor {
        withAlpha(alpha * multiplier)
    }

    private static func clamped(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct CanvasShellStyle: Codable, Sendable, Equatable {
    public var background: CanvasColor
    public var cardFill: CanvasColor
    public var headerFill: CanvasColor
    public var border: CanvasColor
    public var focusedBorder: CanvasColor
    public var gridMinor: CanvasColor
    public var gridMajor: CanvasColor
    public var alignmentGuide: CanvasColor
    public var shadow: CanvasColor
    public var headerHeight: CGFloat
    public var borderWidth: CGFloat
    public var focusedBorderWidth: CGFloat
    public var shadowOffset: CGSize
    public var shadowExpansion: CGFloat

    public init(
        background: CanvasColor = CanvasColor(red: 0.10, green: 0.11, blue: 0.09, alpha: 1),
        cardFill: CanvasColor = CanvasColor(red: 0.10, green: 0.11, blue: 0.09, alpha: 1),
        headerFill: CanvasColor = CanvasColor(red: 1, green: 1, blue: 1, alpha: 0.045),
        border: CanvasColor = CanvasColor(red: 1, green: 1, blue: 1, alpha: 0.22),
        focusedBorder: CanvasColor = CanvasColor(red: 1, green: 1, blue: 1, alpha: 0.34),
        gridMinor: CanvasColor = CanvasColor(red: 1, green: 1, blue: 1, alpha: 0.035),
        gridMajor: CanvasColor = CanvasColor(red: 1, green: 1, blue: 1, alpha: 0.075),
        alignmentGuide: CanvasColor = CanvasColor(red: 0.35, green: 0.65, blue: 1, alpha: 0.72),
        shadow: CanvasColor = CanvasColor(red: 0, green: 0, blue: 0, alpha: 0.12),
        headerHeight: CGFloat = 20,
        borderWidth: CGFloat = 1,
        focusedBorderWidth: CGFloat = 1,
        shadowOffset: CGSize = CGSize(width: 0, height: 4),
        shadowExpansion: CGFloat = 5
    ) {
        self.background = background
        self.cardFill = cardFill
        self.headerFill = headerFill
        self.border = border
        self.focusedBorder = focusedBorder
        self.gridMinor = gridMinor
        self.gridMajor = gridMajor
        self.alignmentGuide = alignmentGuide
        self.shadow = shadow
        self.headerHeight = max(0, headerHeight.isFinite ? headerHeight : 20)
        self.borderWidth = max(0.5, borderWidth.isFinite ? borderWidth : 1)
        self.focusedBorderWidth = max(0.5, focusedBorderWidth.isFinite ? focusedBorderWidth : 1)
        self.shadowOffset = CGSize(
            width: shadowOffset.width.isFinite ? shadowOffset.width : 0,
            height: shadowOffset.height.isFinite ? shadowOffset.height : 0
        )
        self.shadowExpansion = max(0, shadowExpansion.isFinite ? shadowExpansion : 0)
    }
}

public struct CanvasShellSurface: Identifiable, Codable, Sendable, Equatable {
    public var id: LayoutItemID
    public var kind: CanvasSurfaceKind
    public var renderMode: CanvasSurfaceRenderMode
    public var frame: CGRect
    public var headerFrame: CGRect
    public var contentFrame: CGRect
    public var isFocused: Bool

    public init(
        id: LayoutItemID,
        kind: CanvasSurfaceKind,
        renderMode: CanvasSurfaceRenderMode,
        frame: CGRect,
        headerFrame: CGRect,
        contentFrame: CGRect,
        isFocused: Bool
    ) {
        self.id = id
        self.kind = kind
        self.renderMode = renderMode
        self.frame = frame
        self.headerFrame = headerFrame
        self.contentFrame = contentFrame
        self.isFocused = isFocused
    }
}

public struct CanvasShellRect: Codable, Sendable, Equatable {
    public var rect: CGRect
    public var color: CanvasColor
}

public struct CanvasShellLine: Codable, Sendable, Equatable {
    public var start: CGPoint
    public var end: CGPoint
    public var width: CGFloat
    public var color: CanvasColor
}

public enum CanvasShellPrimitive: Codable, Sendable, Equatable {
    case fill(CanvasShellRect)
    case stroke(rect: CGRect, width: CGFloat, color: CanvasColor)
    case line(CanvasShellLine)
}

public struct CanvasShellRenderPlan: Codable, Sendable, Equatable {
    public var viewportSize: CGSize
    public var background: CanvasColor
    public var surfaces: [CanvasShellSurface]
    public var primitives: [CanvasShellPrimitive]

    public init(scene: CanvasScene, style: CanvasShellStyle = CanvasShellStyle()) {
        self.viewportSize = scene.viewportSize
        self.background = style.background

        var primitives: [CanvasShellPrimitive] = []
        primitives.append(contentsOf: Self.gridPrimitives(scene: scene, style: style))

        let surfaces = scene.visibleSurfaces.map { surface in
            Self.shellSurface(for: surface, scene: scene, style: style)
        }
        for surface in surfaces {
            let shadowFrame = surface.frame
                .offsetBy(dx: style.shadowOffset.width, dy: style.shadowOffset.height)
                .insetBy(dx: -style.shadowExpansion, dy: -style.shadowExpansion)
            primitives.append(.fill(CanvasShellRect(rect: shadowFrame, color: style.shadow)))
            primitives.append(.fill(CanvasShellRect(rect: surface.frame, color: style.cardFill)))
        }

        primitives.append(contentsOf: Self.alignmentGuidePrimitives(scene: scene, style: style))

        self.surfaces = surfaces
        self.primitives = primitives.filter(\.hasVisibleArea)
    }

    private static func shellSurface(
        for surface: CanvasSurfaceDescriptor,
        scene: CanvasScene,
        style: CanvasShellStyle
    ) -> CanvasShellSurface {
        let originFrame = scene.surfaceScreenFrame(for: surface)
        let cardSize = CanvasGeometryEngine.cardSize(
            for: surface.frame,
            scale: scene.scale,
            minimumDisplaySize: scene.minimumSurfaceDisplaySize
        )
        let frame = CGRect(origin: originFrame.origin, size: cardSize).standardized
        let headerHeight = min(max(0, style.headerHeight), frame.height)
        let headerFrame = CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: headerHeight
        )
        let contentFrame = CGRect(
            x: frame.minX,
            y: frame.minY + headerHeight,
            width: frame.width,
            height: max(0, frame.height - headerHeight)
        )
        return CanvasShellSurface(
            id: surface.id,
            kind: surface.kind,
            renderMode: surface.renderMode,
            frame: frame,
            headerFrame: headerFrame,
            contentFrame: contentFrame,
            isFocused: surface.isFocused
        )
    }

    private static func gridPrimitives(scene: CanvasScene, style: CanvasShellStyle) -> [CanvasShellPrimitive] {
        let grid = scene.grid
        let screenSpacing = CGFloat(grid.spacing) * scene.transform.scale
        guard screenSpacing >= 4 else { return [] }

        let transform = scene.transform
        let size = scene.viewportSize
        let minimumDocumentPoint = transform.documentPoint(forCanvasPoint: .zero)
        let maximumDocumentPoint = transform.documentPoint(
            forCanvasPoint: CGPoint(x: size.width, y: size.height)
        )
        let startX = floor(Double(minimumDocumentPoint.x) / grid.spacing) * grid.spacing
        let endX = ceil(Double(maximumDocumentPoint.x) / grid.spacing) * grid.spacing
        let startY = floor(Double(minimumDocumentPoint.y) / grid.spacing) * grid.spacing
        let endY = ceil(Double(maximumDocumentPoint.y) / grid.spacing) * grid.spacing

        func isMajor(_ value: Double) -> Bool {
            Int((value / grid.spacing).rounded()).isMultiple(of: grid.majorEvery)
        }

        var primitives: [CanvasShellPrimitive] = []
        var x = startX
        while x <= endX {
            let point = transform.canvasPoint(forDocumentPoint: CGPoint(x: x, y: 0))
            let major = isMajor(x)
            primitives.append(.line(CanvasShellLine(
                start: CGPoint(x: point.x, y: 0),
                end: CGPoint(x: point.x, y: size.height),
                width: major ? 1 : 0.5,
                color: major ? style.gridMajor : style.gridMinor
            )))
            x += grid.spacing
        }

        var y = startY
        while y <= endY {
            let point = transform.canvasPoint(forDocumentPoint: CGPoint(x: 0, y: y))
            let major = isMajor(y)
            primitives.append(.line(CanvasShellLine(
                start: CGPoint(x: 0, y: point.y),
                end: CGPoint(x: size.width, y: point.y),
                width: major ? 1 : 0.5,
                color: major ? style.gridMajor : style.gridMinor
            )))
            y += grid.spacing
        }
        return primitives
    }

    private static func alignmentGuidePrimitives(scene: CanvasScene, style: CanvasShellStyle) -> [CanvasShellPrimitive] {
        let transform = scene.transform
        return scene.alignmentGuides.map { guide in
            switch guide.axis {
            case .horizontal:
                let y = transform.canvasPoint(forDocumentPoint: CGPoint(x: 0, y: guide.position)).y
                return .line(CanvasShellLine(
                    start: CGPoint(x: 0, y: y),
                    end: CGPoint(x: scene.viewportSize.width, y: y),
                    width: 1,
                    color: style.alignmentGuide
                ))
            case .vertical:
                let x = transform.canvasPoint(forDocumentPoint: CGPoint(x: guide.position, y: 0)).x
                return .line(CanvasShellLine(
                    start: CGPoint(x: x, y: 0),
                    end: CGPoint(x: x, y: scene.viewportSize.height),
                    width: 1,
                    color: style.alignmentGuide
                ))
            }
        }
    }
}

private extension CanvasShellPrimitive {
    var hasVisibleArea: Bool {
        switch self {
        case .fill(let rect):
            return rect.rect.width > 0.5 && rect.rect.height > 0.5 && rect.color.alpha > 0
        case .stroke(let rect, let width, let color):
            return rect.width > 0.5 && rect.height > 0.5 && width > 0 && color.alpha > 0
        case .line(let line):
            return line.width > 0 && line.color.alpha > 0
        }
    }
}
