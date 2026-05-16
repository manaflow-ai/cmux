import Foundation

public enum CanvasRenderMode: String, Codable, Sendable, Equatable {
    case liveNative1x
    case previewTexture
    case unmounted
}

public struct CanvasSceneItem: Identifiable, Codable, Sendable, Equatable {
    public var id: LayoutItemID
    public var canvasItem: CanvasItem
    public var frame: PixelRect
    public var renderMode: CanvasRenderMode
    public var isFocused: Bool

    public init(
        id: LayoutItemID,
        canvasItem: CanvasItem,
        frame: PixelRect,
        renderMode: CanvasRenderMode,
        isFocused: Bool
    ) {
        self.id = id
        self.canvasItem = canvasItem
        self.frame = frame
        self.renderMode = renderMode
        self.isFocused = isFocused
    }
}

public struct CanvasMountDirective: Codable, Sendable, Equatable {
    public var itemID: LayoutItemID
    public var paneID: PaneID?
    public var surfaceID: SurfaceID?
    public var frame: PixelRect
    public var renderMode: CanvasRenderMode
    public var isFocused: Bool

    public init(
        itemID: LayoutItemID,
        paneID: PaneID?,
        surfaceID: SurfaceID?,
        frame: PixelRect,
        renderMode: CanvasRenderMode,
        isFocused: Bool
    ) {
        self.itemID = itemID
        self.paneID = paneID
        self.surfaceID = surfaceID
        self.frame = frame
        self.renderMode = renderMode
        self.isFocused = isFocused
    }
}

public struct CanvasSceneSnapshot: Codable, Sendable, Equatable {
    public var document: CanvasDocument
    public var focusedItemID: LayoutItemID?
    public var activeItemID: LayoutItemID?
    public var items: [CanvasSceneItem]
    public var mountDirectives: [CanvasMountDirective]

    public init(
        document: CanvasDocument,
        focusedItemID: LayoutItemID?,
        activeItemID: LayoutItemID? = nil
    ) {
        self.document = document
        self.focusedItemID = focusedItemID
        self.activeItemID = activeItemID ?? focusedItemID

        let resolvedActiveItemID = activeItemID ?? focusedItemID
        let allowsLiveNativeMount = document.viewport.scale >= 0.99
        self.items = document.items.map { item in
            let isFocused = item.id == focusedItemID
            return CanvasSceneItem(
                id: item.id,
                canvasItem: item,
                frame: item.frame,
                renderMode: Self.renderMode(
                    for: item,
                    activeItemID: resolvedActiveItemID,
                    allowsLiveNativeMount: allowsLiveNativeMount
                ),
                isFocused: isFocused
            )
        }
        self.mountDirectives = self.items.map { sceneItem in
            let ids = Self.mountIDs(for: sceneItem.canvasItem)
            return CanvasMountDirective(
                itemID: sceneItem.id,
                paneID: ids.paneID,
                surfaceID: ids.surfaceID,
                frame: sceneItem.frame,
                renderMode: sceneItem.renderMode,
                isFocused: sceneItem.isFocused
            )
        }
    }

    public var activeMountDirective: CanvasMountDirective? {
        mountDirectives.first { $0.renderMode == .liveNative1x }
    }

    private static func renderMode(
        for item: CanvasItem,
        activeItemID: LayoutItemID?,
        allowsLiveNativeMount: Bool
    ) -> CanvasRenderMode {
        guard allowsLiveNativeMount else { return .previewTexture }
        guard let activeItemID else { return .previewTexture }
        return item.id == activeItemID ? .liveNative1x : .previewTexture
    }

    private static func mountIDs(for item: CanvasItem) -> (paneID: PaneID?, surfaceID: SurfaceID?) {
        switch item.content {
        case .pane(let paneID):
            return (paneID, nil)
        case .surface(let surfaceID):
            return (nil, surfaceID)
        case .group:
            return (nil, nil)
        }
    }
}
