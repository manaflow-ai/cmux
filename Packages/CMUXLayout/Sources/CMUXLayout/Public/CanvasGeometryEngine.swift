import CoreGraphics
import Foundation

public enum CanvasResizeHandle: String, CaseIterable, Codable, Identifiable, Sendable {
    case top
    case bottom
    case left
    case right
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var id: Self { self }

    public var adjustsLeading: Bool {
        switch self {
        case .left, .topLeft, .bottomLeft:
            return true
        case .top, .bottom, .right, .topRight, .bottomRight:
            return false
        }
    }

    public var adjustsTrailing: Bool {
        switch self {
        case .right, .topRight, .bottomRight:
            return true
        case .top, .bottom, .left, .topLeft, .bottomLeft:
            return false
        }
    }

    public var adjustsTop: Bool {
        switch self {
        case .top, .topLeft, .topRight:
            return true
        case .bottom, .left, .right, .bottomLeft, .bottomRight:
            return false
        }
    }

    public var adjustsBottom: Bool {
        switch self {
        case .bottom, .bottomLeft, .bottomRight:
            return true
        case .top, .left, .right, .topLeft, .topRight:
            return false
        }
    }
}

public struct CanvasResizeHitRegion: Sendable, Equatable {
    public var handle: CanvasResizeHandle
    public var frame: CGRect

    public init(handle: CanvasResizeHandle, frame: CGRect) {
        self.handle = handle
        self.frame = frame
    }
}

public struct CanvasResizeHitArea: Sendable, Equatable {
    public var cardSize: CGSize
    public var edgeHitSize: CGFloat
    public var cornerHitSize: CGFloat

    public init(cardSize: CGSize, edgeHitSize: CGFloat = 16, cornerHitSize: CGFloat = 44) {
        self.cardSize = cardSize
        self.edgeHitSize = edgeHitSize
        self.cornerHitSize = cornerHitSize
    }

    public func handle(at point: CGPoint) -> CanvasResizeHandle? {
        guard point.x >= 0,
              point.y >= 0,
              point.x <= cardSize.width,
              point.y <= cardSize.height else {
            return nil
        }

        let inLeadingCorner = point.x <= cornerHitSize
        let inTrailingCorner = cardSize.width - point.x <= cornerHitSize
        let inTopCorner = point.y <= cornerHitSize
        let inBottomCorner = cardSize.height - point.y <= cornerHitSize

        switch (inLeadingCorner, inTrailingCorner, inTopCorner, inBottomCorner) {
        case (true, _, true, _):
            return .topLeft
        case (_, true, true, _):
            return .topRight
        case (true, _, _, true):
            return .bottomLeft
        case (_, true, _, true):
            return .bottomRight
        default:
            break
        }

        let nearLeadingEdge = point.x <= edgeHitSize
        let nearTrailingEdge = cardSize.width - point.x <= edgeHitSize
        let nearTopEdge = point.y <= edgeHitSize
        let nearBottomEdge = cardSize.height - point.y <= edgeHitSize

        if nearLeadingEdge { return .left }
        if nearTrailingEdge { return .right }
        if nearTopEdge { return .top }
        if nearBottomEdge { return .bottom }
        return nil
    }

    public func hitRegions() -> [CanvasResizeHitRegion] {
        guard cardSize.width > 1, cardSize.height > 1 else { return [] }
        let edge = max(1, min(edgeHitSize, min(cardSize.width, cardSize.height)))
        let corner = max(edge, min(cornerHitSize, min(cardSize.width, cardSize.height)))
        let horizontalWidth = max(1, cardSize.width - (corner * 2))
        let verticalHeight = max(1, cardSize.height - (corner * 2))

        return [
            CanvasResizeHitRegion(handle: .top, frame: CGRect(x: corner, y: 0, width: horizontalWidth, height: edge)),
            CanvasResizeHitRegion(handle: .bottom, frame: CGRect(x: corner, y: cardSize.height - edge, width: horizontalWidth, height: edge)),
            CanvasResizeHitRegion(handle: .left, frame: CGRect(x: 0, y: corner, width: edge, height: verticalHeight)),
            CanvasResizeHitRegion(handle: .right, frame: CGRect(x: cardSize.width - edge, y: corner, width: edge, height: verticalHeight)),
            CanvasResizeHitRegion(handle: .topLeft, frame: CGRect(x: 0, y: 0, width: corner, height: corner)),
            CanvasResizeHitRegion(handle: .topRight, frame: CGRect(x: cardSize.width - corner, y: 0, width: corner, height: corner)),
            CanvasResizeHitRegion(handle: .bottomLeft, frame: CGRect(x: 0, y: cardSize.height - corner, width: corner, height: corner)),
            CanvasResizeHitRegion(handle: .bottomRight, frame: CGRect(x: cardSize.width - corner, y: cardSize.height - corner, width: corner, height: corner))
        ]
    }
}

public struct CanvasGrid: Codable, Sendable, Equatable {
    public static let freeformDefault = CanvasGrid(spacing: 8, majorEvery: 8)

    public var spacing: Double
    public var majorEvery: Int

    public init(spacing: Double = 8, majorEvery: Int = 8) {
        self.spacing = max(1, spacing)
        self.majorEvery = max(1, majorEvery)
    }
}

public enum CanvasAlignmentGuideAxis: String, Codable, Sendable, Equatable {
    case vertical
    case horizontal
}

public struct CanvasAlignmentGuide: Codable, Sendable, Equatable {
    public var axis: CanvasAlignmentGuideAxis
    public var position: Double
    public var rangeStart: Double
    public var rangeEnd: Double

    public init(axis: CanvasAlignmentGuideAxis, position: Double, rangeStart: Double, rangeEnd: Double) {
        self.axis = axis
        self.position = position
        self.rangeStart = min(rangeStart, rangeEnd)
        self.rangeEnd = max(rangeStart, rangeEnd)
    }
}

public struct CanvasInteractionConfiguration: Sendable, Equatable {
    public var grid: CanvasGrid?
    public var gridSnapDistanceInScreenPoints: Double
    public var alignmentSnapDistanceInScreenPoints: Double
    public var guidePadding: Double
    public var minimumFrameSize: CGSize

    public init(
        grid: CanvasGrid? = .freeformDefault,
        gridSnapDistanceInScreenPoints: Double = 6,
        alignmentSnapDistanceInScreenPoints: Double = 6,
        guidePadding: Double = 24,
        minimumFrameSize: CGSize = CGSize(width: 240, height: 170)
    ) {
        self.grid = grid
        self.gridSnapDistanceInScreenPoints = max(0, gridSnapDistanceInScreenPoints)
        self.alignmentSnapDistanceInScreenPoints = max(0, alignmentSnapDistanceInScreenPoints)
        self.guidePadding = max(0, guidePadding)
        self.minimumFrameSize = CGSize(
            width: max(1, minimumFrameSize.width),
            height: max(1, minimumFrameSize.height)
        )
    }
}

public struct CanvasTransform: Sendable, Equatable {
    public var documentBounds: CGRect
    public var documentOrigin: CGPoint
    public var scale: CGFloat
    public var padding: CGFloat

    public init(
        documentBounds: CGRect,
        scale: CGFloat,
        padding: CGFloat = 0,
        documentOrigin: CGPoint? = nil
    ) {
        self.documentBounds = documentBounds
        self.documentOrigin = documentOrigin ?? CGPoint(
            x: min(0, documentBounds.minX),
            y: min(0, documentBounds.minY)
        )
        self.scale = max(0.0001, scale)
        self.padding = padding
    }

    public func documentPoint(forCanvasPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: ((point.x - padding) / scale) + documentOrigin.x,
            y: ((point.y - padding) / scale) + documentOrigin.y
        )
    }

    public func canvasPoint(forDocumentPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: padding + ((point.x - documentOrigin.x) * scale),
            y: padding + ((point.y - documentOrigin.y) * scale)
        )
    }

    public func canvasRect(forDocumentFrame frame: PixelRect) -> CGRect {
        let origin = canvasPoint(forDocumentPoint: CGPoint(x: frame.x, y: frame.y))
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: CGFloat(frame.width) * scale,
            height: CGFloat(frame.height) * scale
        )
    }
}

public struct CanvasContentBounds: Sendable, Equatable {
    public var documentBounds: CGRect
    public var size: CGSize

    public init(documentBounds: CGRect, size: CGSize) {
        self.documentBounds = documentBounds
        self.size = size
    }
}

public struct CanvasSurfacePresentation: Sendable, Equatable {
    public var frameInWindow: CGRect
    public var nativeContentSize: CGSize
    public var scale: CGFloat

    public init(frameInWindow: CGRect, nativeContentSize: CGSize, scale: CGFloat) {
        self.frameInWindow = frameInWindow
        self.nativeContentSize = CGSize(
            width: max(1, nativeContentSize.width),
            height: max(1, nativeContentSize.height)
        )
        self.scale = max(0.0001, scale)
    }

    public var visualContentSize: CGSize {
        CGSize(
            width: max(1, frameInWindow.width),
            height: max(1, frameInWindow.height)
        )
    }

    public var horizontalScale: CGFloat {
        frameInWindow.width / nativeContentSize.width
    }

    public var verticalScale: CGFloat {
        frameInWindow.height / nativeContentSize.height
    }
}

public struct CanvasDragSession: Sendable, Equatable {
    public var itemID: LayoutItemID
    public var startFrame: PixelRect
    public var pointerOffsetInDocument: CGSize

    public init(itemID: LayoutItemID, startFrame: PixelRect, pointerOffsetInDocument: CGSize) {
        self.itemID = itemID
        self.startFrame = startFrame
        self.pointerOffsetInDocument = pointerOffsetInDocument
    }
}

public struct CanvasResizeSession: Sendable, Equatable {
    public var itemID: LayoutItemID
    public var handle: CanvasResizeHandle
    public var startFrame: PixelRect
    public var startPointInDocument: CGPoint

    public init(
        itemID: LayoutItemID,
        handle: CanvasResizeHandle,
        startFrame: PixelRect,
        startPointInDocument: CGPoint
    ) {
        self.itemID = itemID
        self.handle = handle
        self.startFrame = startFrame
        self.startPointInDocument = startPointInDocument
    }
}

public struct CanvasInteractionGeometry: Sendable, Equatable {
    public var frame: PixelRect
    public var guides: [CanvasAlignmentGuide]

    public init(frame: PixelRect, guides: [CanvasAlignmentGuide] = []) {
        self.frame = frame
        self.guides = guides
    }
}

public enum CanvasGeometryEngine {
    public static func contentBounds(
        for items: [CanvasItem],
        scale: CGFloat,
        viewportSize: CGSize,
        padding: CGFloat,
        fallbackDocumentBounds: CGRect = CGRect(x: 0, y: 0, width: 1_200, height: 800)
    ) -> CanvasContentBounds {
        let itemBounds = items
            .map { $0.frame.cgRect }
            .reduce(CGRect.null) { $0.union($1) }
        let documentBounds = itemBounds.isNull ? fallbackDocumentBounds : itemBounds
        let safeScale = max(0.0001, scale)
        let width = max(viewportSize.width, documentBounds.width * safeScale + (padding * 2))
        let height = max(viewportSize.height, documentBounds.height * safeScale + (padding * 2))
        return CanvasContentBounds(documentBounds: documentBounds, size: CGSize(width: width, height: height))
    }

    public static func viewportAnchoredContentBounds(
        for items: [CanvasItem],
        scale: CGFloat,
        viewport: CanvasViewport,
        viewportSize: CGSize,
        padding: CGFloat
    ) -> CanvasContentBounds {
        let safeScale = max(0.0001, scale)
        let viewportDocumentRect = CGRect(
            x: CGFloat(viewport.visibleRect.x),
            y: CGFloat(viewport.visibleRect.y),
            width: max(viewport.visibleRect.width, Double(viewportSize.width / safeScale)),
            height: max(viewport.visibleRect.height, Double(viewportSize.height / safeScale))
        )
        let itemBounds = items
            .map { $0.frame.cgRect }
            .reduce(CGRect.null) { $0.union($1) }
        let documentBounds = itemBounds.isNull
            ? viewportDocumentRect
            : itemBounds.union(viewportDocumentRect)
        let width = max(
            viewportSize.width,
            (documentBounds.maxX - CGFloat(viewport.visibleRect.x)) * safeScale + (padding * 2)
        )
        let height = max(
            viewportSize.height,
            (documentBounds.maxY - CGFloat(viewport.visibleRect.y)) * safeScale + (padding * 2)
        )
        return CanvasContentBounds(
            documentBounds: documentBounds,
            size: CGSize(width: width, height: height)
        )
    }

    public static func visibleDocumentRect(
        viewport: CanvasViewport,
        viewportSize: CGSize,
        scale: CGFloat,
        overscanScreenPoints: CGFloat = 0
    ) -> CGRect {
        let safeScale = max(0.0001, scale)
        let overscan = max(0, overscanScreenPoints) / safeScale
        return CGRect(
            x: CGFloat(viewport.visibleRect.x) - overscan,
            y: CGFloat(viewport.visibleRect.y) - overscan,
            width: max(1, viewportSize.width / safeScale) + (overscan * 2),
            height: max(1, viewportSize.height / safeScale) + (overscan * 2)
        )
    }

    public static func visibleItems(
        _ items: [CanvasItem],
        viewport: CanvasViewport,
        viewportSize: CGSize,
        scale: CGFloat,
        overscanScreenPoints: CGFloat = 160
    ) -> [CanvasItem] {
        let visibleRect = visibleDocumentRect(
            viewport: viewport,
            viewportSize: viewportSize,
            scale: scale,
            overscanScreenPoints: overscanScreenPoints
        )
        return items.filter { item in
            item.frame.cgRect.intersects(visibleRect)
        }
    }

    public static func cardSize(for frame: PixelRect, scale: CGFloat, minimumDisplaySize: CGSize) -> CGSize {
        CGSize(
            width: max(minimumDisplaySize.width, CGFloat(frame.width) * scale),
            height: max(minimumDisplaySize.height, CGFloat(frame.height) * scale)
        )
    }

    public static func minimumFrameSize(scale: CGFloat, minimumDisplaySize: CGSize) -> CGSize {
        let safeScale = max(0.0001, scale)
        return CGSize(
            width: minimumDisplaySize.width / safeScale,
            height: minimumDisplaySize.height / safeScale
        )
    }

    public static func adjustedFrame(for frame: PixelRect, in documentBounds: CGRect) -> CGRect {
        CGRect(
            x: CGFloat(frame.x) - min(0, documentBounds.minX),
            y: CGFloat(frame.y) - min(0, documentBounds.minY),
            width: CGFloat(frame.width),
            height: CGFloat(frame.height)
        )
    }

    public static func beginDrag(
        itemID: LayoutItemID,
        frame: PixelRect,
        pointerCanvasPoint: CGPoint,
        transform: CanvasTransform
    ) -> CanvasDragSession {
        let pointer = transform.documentPoint(forCanvasPoint: pointerCanvasPoint)
        return CanvasDragSession(
            itemID: itemID,
            startFrame: frame,
            pointerOffsetInDocument: CGSize(width: pointer.x - CGFloat(frame.x), height: pointer.y - CGFloat(frame.y))
        )
    }

    public static func updateDrag(
        session: CanvasDragSession,
        pointerCanvasPoint: CGPoint,
        transform: CanvasTransform,
        items: [CanvasItem],
        configuration: CanvasInteractionConfiguration = CanvasInteractionConfiguration()
    ) -> CanvasInteractionGeometry {
        let pointer = transform.documentPoint(forCanvasPoint: pointerCanvasPoint)
        let candidate = PixelRect(
            x: Double(pointer.x - session.pointerOffsetInDocument.width),
            y: Double(pointer.y - session.pointerOffsetInDocument.height),
            width: session.startFrame.width,
            height: session.startFrame.height
        )
        return snappedMoveFrame(
            candidate,
            itemID: session.itemID,
            items: items,
            scale: transform.scale,
            configuration: configuration
        )
    }

    public static func moveFrame(
        itemID: LayoutItemID,
        baseFrame: PixelRect,
        canvasTranslation: CGSize,
        scale: CGFloat,
        items: [CanvasItem],
        configuration: CanvasInteractionConfiguration = CanvasInteractionConfiguration()
    ) -> CanvasInteractionGeometry {
        let safeScale = max(0.0001, scale)
        return moveFrame(
            itemID: itemID,
            baseFrame: baseFrame,
            documentTranslation: CGSize(
                width: canvasTranslation.width / safeScale,
                height: canvasTranslation.height / safeScale
            ),
            items: items,
            scale: safeScale,
            configuration: configuration
        )
    }

    public static func moveFrame(
        itemID: LayoutItemID,
        baseFrame: PixelRect,
        documentTranslation: CGSize,
        items: [CanvasItem],
        scale: CGFloat,
        configuration: CanvasInteractionConfiguration = CanvasInteractionConfiguration()
    ) -> CanvasInteractionGeometry {
        let candidate = PixelRect(
            x: baseFrame.x + Double(documentTranslation.width),
            y: baseFrame.y + Double(documentTranslation.height),
            width: baseFrame.width,
            height: baseFrame.height
        )
        return snappedMoveFrame(
            candidate.normalized(minimumSize: configuration.minimumFrameSize),
            itemID: itemID,
            items: items,
            scale: scale,
            configuration: configuration
        )
    }

    public static func beginResize(
        itemID: LayoutItemID,
        handle: CanvasResizeHandle,
        frame: PixelRect,
        pointerCanvasPoint: CGPoint,
        transform: CanvasTransform
    ) -> CanvasResizeSession {
        CanvasResizeSession(
            itemID: itemID,
            handle: handle,
            startFrame: frame,
            startPointInDocument: transform.documentPoint(forCanvasPoint: pointerCanvasPoint)
        )
    }

    public static func updateResize(
        session: CanvasResizeSession,
        pointerCanvasPoint: CGPoint,
        transform: CanvasTransform,
        items: [CanvasItem],
        configuration: CanvasInteractionConfiguration = CanvasInteractionConfiguration()
    ) -> CanvasInteractionGeometry {
        let pointer = transform.documentPoint(forCanvasPoint: pointerCanvasPoint)
        let translation = CGSize(
            width: pointer.x - session.startPointInDocument.x,
            height: pointer.y - session.startPointInDocument.y
        )
        return resizeFrame(
            itemID: session.itemID,
            baseFrame: session.startFrame,
            documentTranslation: translation,
            handle: session.handle,
            items: items,
            scale: transform.scale,
            configuration: configuration
        )
    }

    public static func resizeFrame(
        itemID: LayoutItemID,
        baseFrame: PixelRect,
        canvasTranslation: CGSize,
        scale: CGFloat,
        handle: CanvasResizeHandle,
        items: [CanvasItem],
        configuration: CanvasInteractionConfiguration = CanvasInteractionConfiguration()
    ) -> CanvasInteractionGeometry {
        let safeScale = max(0.0001, scale)
        return resizeFrame(
            itemID: itemID,
            baseFrame: baseFrame,
            documentTranslation: CGSize(
                width: canvasTranslation.width / safeScale,
                height: canvasTranslation.height / safeScale
            ),
            handle: handle,
            items: items,
            scale: safeScale,
            configuration: configuration
        )
    }

    public static func resizeFrame(
        itemID: LayoutItemID,
        baseFrame: PixelRect,
        documentTranslation: CGSize,
        handle: CanvasResizeHandle,
        items: [CanvasItem],
        scale: CGFloat,
        configuration: CanvasInteractionConfiguration = CanvasInteractionConfiguration()
    ) -> CanvasInteractionGeometry {
        var frame = unsnappedResizeFrame(
            baseFrame: baseFrame,
            documentTranslation: documentTranslation,
            handle: handle,
            minimumFrameSize: configuration.minimumFrameSize
        )
        var guides: [CanvasAlignmentGuide] = []

        if handle.adjustsLeading || handle.adjustsTrailing {
            let value = handle.adjustsLeading ? frame.minX : frame.maxX
            let snap = snap(
                value: value,
                axis: .vertical,
                movingFrame: frame,
                itemID: itemID,
                items: items,
                scale: scale,
                configuration: configuration
            )
            if let delta = snap.delta {
                frame = resizeFrame(frame, handle: handle, deltaX: delta, deltaY: 0, minimumSize: configuration.minimumFrameSize)
                guides.append(contentsOf: snap.guides)
            }
        }

        if handle.adjustsTop || handle.adjustsBottom {
            let value = handle.adjustsTop ? frame.minY : frame.maxY
            let snap = snap(
                value: value,
                axis: .horizontal,
                movingFrame: frame,
                itemID: itemID,
                items: items,
                scale: scale,
                configuration: configuration
            )
            if let delta = snap.delta {
                frame = resizeFrame(frame, handle: handle, deltaX: 0, deltaY: delta, minimumSize: configuration.minimumFrameSize)
                guides.append(contentsOf: snap.guides)
            }
        }

        return CanvasInteractionGeometry(frame: frame.normalized(minimumSize: configuration.minimumFrameSize), guides: guides)
    }

    private static func unsnappedResizeFrame(
        baseFrame: PixelRect,
        documentTranslation: CGSize,
        handle: CanvasResizeHandle,
        minimumFrameSize: CGSize
    ) -> PixelRect {
        let minimumWidth = Double(minimumFrameSize.width)
        let minimumHeight = Double(minimumFrameSize.height)
        let deltaX = Double(documentTranslation.width)
        let deltaY = Double(documentTranslation.height)

        var x = baseFrame.x
        var y = baseFrame.y
        var width = baseFrame.width
        var height = baseFrame.height

        if handle.adjustsLeading {
            let maxX = baseFrame.maxX
            x = min(baseFrame.x + deltaX, maxX - minimumWidth)
            width = maxX - x
        } else if handle.adjustsTrailing {
            width = max(minimumWidth, baseFrame.width + deltaX)
        }

        if handle.adjustsTop {
            let maxY = baseFrame.maxY
            y = min(baseFrame.y + deltaY, maxY - minimumHeight)
            height = maxY - y
        } else if handle.adjustsBottom {
            height = max(minimumHeight, baseFrame.height + deltaY)
        }

        return PixelRect(x: x, y: y, width: width, height: height)
    }

    private static func resizeFrame(
        _ frame: PixelRect,
        handle: CanvasResizeHandle,
        deltaX: Double,
        deltaY: Double,
        minimumSize: CGSize
    ) -> PixelRect {
        var x = frame.x
        var y = frame.y
        var width = frame.width
        var height = frame.height

        if handle.adjustsLeading {
            let maxX = frame.maxX
            x = min(x + deltaX, maxX - Double(minimumSize.width))
            width = maxX - x
        } else if handle.adjustsTrailing {
            width = max(Double(minimumSize.width), width + deltaX)
        }

        if handle.adjustsTop {
            let maxY = frame.maxY
            y = min(y + deltaY, maxY - Double(minimumSize.height))
            height = maxY - y
        } else if handle.adjustsBottom {
            height = max(Double(minimumSize.height), height + deltaY)
        }

        return PixelRect(x: x, y: y, width: width, height: height)
    }

    private static func snappedMoveFrame(
        _ frame: PixelRect,
        itemID: LayoutItemID,
        items: [CanvasItem],
        scale: CGFloat,
        configuration: CanvasInteractionConfiguration
    ) -> CanvasInteractionGeometry {
        let xSnap = snapMovableAxis(
            values: [frame.minX, frame.midX, frame.maxX],
            axis: .vertical,
            movingFrame: frame,
            itemID: itemID,
            items: items,
            scale: scale,
            configuration: configuration
        )
        var snapped = PixelRect(
            x: frame.x + (xSnap.delta ?? 0),
            y: frame.y,
            width: frame.width,
            height: frame.height
        )
        let ySnap = snapMovableAxis(
            values: [snapped.minY, snapped.midY, snapped.maxY],
            axis: .horizontal,
            movingFrame: snapped,
            itemID: itemID,
            items: items,
            scale: scale,
            configuration: configuration
        )
        if let delta = ySnap.delta {
            snapped = PixelRect(x: snapped.x, y: snapped.y + delta, width: snapped.width, height: snapped.height)
        }
        return CanvasInteractionGeometry(frame: snapped, guides: xSnap.guides + ySnap.guides)
    }

    private static func snapMovableAxis(
        values: [Double],
        axis: CanvasAlignmentGuideAxis,
        movingFrame: PixelRect,
        itemID: LayoutItemID,
        items: [CanvasItem],
        scale: CGFloat,
        configuration: CanvasInteractionConfiguration
    ) -> (delta: Double?, guides: [CanvasAlignmentGuide]) {
        var best: (delta: Double, guides: [CanvasAlignmentGuide], distance: Double)?
        for value in values {
            let snap = snap(
                value: value,
                axis: axis,
                movingFrame: movingFrame,
                itemID: itemID,
                items: items,
                scale: scale,
                configuration: configuration
            )
            guard let delta = snap.delta else { continue }
            let distance = abs(delta)
            if best == nil || distance < best!.distance {
                best = (delta, snap.guides, distance)
            }
        }
        return (best?.delta, best?.guides ?? [])
    }

    private static func snap(
        value: Double,
        axis: CanvasAlignmentGuideAxis,
        movingFrame: PixelRect,
        itemID: LayoutItemID,
        items: [CanvasItem],
        scale: CGFloat,
        configuration: CanvasInteractionConfiguration
    ) -> (delta: Double?, guides: [CanvasAlignmentGuide]) {
        let safeScale = max(0.0001, Double(scale))
        let gridThreshold = configuration.gridSnapDistanceInScreenPoints / safeScale
        let alignmentThreshold = configuration.alignmentSnapDistanceInScreenPoints / safeScale

        var best: (delta: Double, guides: [CanvasAlignmentGuide], distance: Double)?

        if let grid = configuration.grid, grid.spacing > 0, gridThreshold > 0 {
            let snappedValue = (value / grid.spacing).rounded() * grid.spacing
            let delta = snappedValue - value
            if abs(delta) <= gridThreshold {
                best = (delta, [], abs(delta))
            }
        }

        if alignmentThreshold > 0 {
            for item in items where item.id != itemID {
                for target in targets(for: item.frame, axis: axis) {
                    let delta = target - value
                    let distance = abs(delta)
                    guard distance <= alignmentThreshold else { continue }
                    let guide = guide(
                        axis: axis,
                        targetValue: target,
                        movingFrame: movingFrame,
                        targetFrame: item.frame,
                        padding: configuration.guidePadding
                    )
                    if best == nil || distance < best!.distance {
                        best = (delta, [guide], distance)
                    }
                }
            }
        }

        return (best?.delta, best?.guides ?? [])
    }

    private static func targets(for frame: PixelRect, axis: CanvasAlignmentGuideAxis) -> [Double] {
        switch axis {
        case .vertical:
            return [frame.minX, frame.midX, frame.maxX]
        case .horizontal:
            return [frame.minY, frame.midY, frame.maxY]
        }
    }

    private static func guide(
        axis: CanvasAlignmentGuideAxis,
        targetValue: Double,
        movingFrame: PixelRect,
        targetFrame: PixelRect,
        padding: Double
    ) -> CanvasAlignmentGuide {
        switch axis {
        case .vertical:
            return CanvasAlignmentGuide(
                axis: axis,
                position: targetValue,
                rangeStart: min(movingFrame.minY, targetFrame.minY) - padding,
                rangeEnd: max(movingFrame.maxY, targetFrame.maxY) + padding
            )
        case .horizontal:
            return CanvasAlignmentGuide(
                axis: axis,
                position: targetValue,
                rangeStart: min(movingFrame.minX, targetFrame.minX) - padding,
                rangeEnd: max(movingFrame.maxX, targetFrame.maxX) + padding
            )
        }
    }
}

private extension PixelRect {
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var minX: Double { x }
    var maxX: Double { x + width }
    var midX: Double { x + (width / 2) }
    var minY: Double { y }
    var maxY: Double { y + height }
    var midY: Double { y + (height / 2) }

    func normalized(minimumSize: CGSize) -> PixelRect {
        PixelRect(
            x: x.isFinite ? x : 0,
            y: y.isFinite ? y : 0,
            width: max(Double(minimumSize.width), width.isFinite ? width : Double(minimumSize.width)),
            height: max(Double(minimumSize.height), height.isFinite ? height : Double(minimumSize.height))
        )
    }
}
