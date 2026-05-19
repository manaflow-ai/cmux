import Foundation

public struct CanvasID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let id: UUID

    public init() {
        self.id = UUID()
    }

    public init(id: UUID) {
        self.id = id
    }

    public var description: String {
        id.uuidString
    }
}

public struct LayoutItemID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let id: UUID

    public init() {
        self.id = UUID()
    }

    public init(id: UUID) {
        self.id = id
    }

    public init(paneID: PaneID) {
        self.id = paneID.id
    }

    public init(surfaceID: SurfaceID) {
        self.id = surfaceID.uuid
    }

    public var description: String {
        id.uuidString
    }
}

public enum CanvasLayoutPolicy: String, Codable, Sendable, Equatable {
    case freeform
    case scrollingColumns
}

public struct CanvasViewport: Codable, Sendable, Equatable {
    public static let minimumScale: Double = 0.05

    public var visibleRect: PixelRect
    public var scale: Double

    public init(
        visibleRect: PixelRect = PixelRect(x: 0, y: 0, width: 1_200, height: 800),
        scale: Double = 1
    ) {
        self.visibleRect = visibleRect
        self.scale = Self.normalizedScale(scale)
    }

    public static let native = CanvasViewport()

    public mutating func setScale(_ scale: Double) {
        self.scale = Self.normalizedScale(scale)
    }

    public mutating func setVisibleRect(_ rect: PixelRect) {
        visibleRect = PixelRect(
            x: rect.x.isFinite ? rect.x : 0,
            y: rect.y.isFinite ? rect.y : 0,
            width: max(1, rect.width.isFinite ? rect.width : visibleRect.width),
            height: max(1, rect.height.isFinite ? rect.height : visibleRect.height)
        )
    }

    public mutating func panBy(dx: Double, dy: Double) {
        setVisibleRect(
            PixelRect(
                x: visibleRect.x + (dx.isFinite ? dx : 0),
                y: visibleRect.y + (dy.isFinite ? dy : 0),
                width: visibleRect.width,
                height: visibleRect.height
            )
        )
    }

    private static func normalizedScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return 1 }
        return max(minimumScale, scale)
    }
}

public enum CanvasViewportZoom {
    public static let minimumScale: Double = 0.16
    public static let maximumScale: Double = 1.0

    public static func presentationScale(for viewport: CanvasViewport) -> Double {
        clampedScale(viewport.scale)
    }

    public static func clampedScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return maximumScale }
        return min(max(scale, minimumScale), maximumScale)
    }

    public static func scaleAfterWheel(deltaY: Double, currentScale: Double) -> Double {
        guard deltaY.isFinite else { return clampedScale(currentScale) }
        let boundedDelta = min(max(deltaY, -80), 80)
        let factor = exp(boundedDelta * 0.002)
        return clampedScale(currentScale * factor)
    }

    public static func scaleAfterMagnification(_ magnification: Double, currentScale: Double) -> Double {
        guard magnification.isFinite else { return clampedScale(currentScale) }
        let factor = min(max(1 + magnification, 0.5), 1.5)
        return clampedScale(currentScale * factor)
    }

    public static func smartZoomScale(currentScale: Double) -> Double {
        currentScale < 0.99 ? maximumScale : 0.5
    }
}

public struct CanvasItem: Identifiable, Codable, Sendable, Equatable {
    public enum Content: Codable, Sendable, Equatable {
        case pane(PaneID)
        case surface(SurfaceID)
        case group([LayoutItemID])
    }

    public var id: LayoutItemID
    public var content: Content
    public var frame: PixelRect
    public var zIndex: Int
    public var isNativeResolution: Bool

    public init(
        id: LayoutItemID? = nil,
        content: Content,
        frame: PixelRect,
        zIndex: Int = 0,
        isNativeResolution: Bool = true
    ) {
        self.id = id ?? content.stableItemID ?? LayoutItemID()
        self.content = content
        self.frame = frame
        self.zIndex = zIndex
        self.isNativeResolution = isNativeResolution
    }
}

private extension CanvasItem.Content {
    var stableItemID: LayoutItemID? {
        switch self {
        case .pane(let paneID):
            return LayoutItemID(paneID: paneID)
        case .surface(let surfaceID):
            return LayoutItemID(surfaceID: surfaceID)
        case .group:
            return nil
        }
    }
}

public struct CanvasDocument: Identifiable, Codable, Sendable, Equatable {
    public var id: CanvasID
    public var policy: CanvasLayoutPolicy
    public var viewport: CanvasViewport
    public var items: [CanvasItem]

    public init(
        id: CanvasID = CanvasID(),
        policy: CanvasLayoutPolicy = .scrollingColumns,
        viewport: CanvasViewport = .native,
        items: [CanvasItem] = []
    ) {
        self.id = id
        self.policy = policy
        self.viewport = viewport
        self.items = items
    }

    public static func defaultScrollingColumns(
        panes: [PaneID],
        viewport: CanvasViewport = .native,
        columnWidth: Double = 1_200,
        columnHeight: Double = 800,
        gap: Double = 16
    ) -> CanvasDocument {
        let items = panes.enumerated().map { index, paneID in
            CanvasItem(
                content: .pane(paneID),
                frame: PixelRect(
                    x: Double(index) * (columnWidth + gap),
                    y: 0,
                    width: columnWidth,
                    height: columnHeight
                ),
                zIndex: index,
                isNativeResolution: true
            )
        }
        return CanvasDocument(policy: .scrollingColumns, viewport: viewport, items: items)
    }

    public mutating func moveItem(_ itemID: LayoutItemID, to frame: PixelRect) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].frame = frame
        policy = .freeform
    }

    public mutating func resizeItem(_ itemID: LayoutItemID, to frame: PixelRect) {
        moveItem(itemID, to: frame)
    }
}
