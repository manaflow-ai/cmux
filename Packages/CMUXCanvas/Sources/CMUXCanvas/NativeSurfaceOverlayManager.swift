import CMUXLayout
import CoreGraphics
import Foundation

public struct CanvasNativeOverlayConfiguration: Sendable, Equatable {
    public var minimumNativeScale: CGFloat
    public var activeSurfaceID: LayoutItemID?

    public init(minimumNativeScale: CGFloat = 0.995, activeSurfaceID: LayoutItemID? = nil) {
        self.minimumNativeScale = max(0.0001, minimumNativeScale.isFinite ? minimumNativeScale : 0.995)
        self.activeSurfaceID = activeSurfaceID
    }
}

public struct CanvasNativeOverlay: Identifiable, Sendable, Equatable {
    public var id: LayoutItemID
    public var kind: CanvasSurfaceKind
    public var frameInWindow: CGRect
    public var nativeContentSize: CGSize
    public var zIndex: Int

    public init(
        id: LayoutItemID,
        kind: CanvasSurfaceKind,
        frameInWindow: CGRect,
        nativeContentSize: CGSize,
        zIndex: Int
    ) {
        self.id = id
        self.kind = kind
        self.frameInWindow = frameInWindow
        self.nativeContentSize = CGSize(
            width: max(1, nativeContentSize.width),
            height: max(1, nativeContentSize.height)
        )
        self.zIndex = zIndex
    }

    public func presentation(frameInWindow: CGRect? = nil, scale: CGFloat) -> CanvasSurfacePresentation {
        CanvasSurfacePresentation(
            frameInWindow: frameInWindow ?? self.frameInWindow,
            nativeContentSize: nativeContentSize,
            scale: scale
        )
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

public struct NativeSurfaceOverlayManager: Sendable, Equatable {
    public var configuration: CanvasNativeOverlayConfiguration

    public init(configuration: CanvasNativeOverlayConfiguration = CanvasNativeOverlayConfiguration()) {
        self.configuration = configuration
    }

    public func plan(scene: CanvasScene) -> CanvasNativeOverlayPlan {
        var nativeOverlays: [CanvasNativeOverlay] = []
        var textureSurfaces: [CanvasSurfaceDescriptor] = []

        for surface in scene.visibleSurfaces {
            if shouldUseNativeOverlay(surface: surface, sceneScale: scene.scale) {
                let frame = scene.surfaceScreenFrame(for: surface)
                nativeOverlays.append(
                    CanvasNativeOverlay(
                        id: surface.id,
                        kind: surface.kind,
                        frameInWindow: frame,
                        nativeContentSize: CGSize(width: surface.frame.width, height: surface.frame.height),
                        zIndex: surface.zIndex
                    )
                )
            } else {
                textureSurfaces.append(surface)
            }
        }

        return CanvasNativeOverlayPlan(
            nativeOverlays: nativeOverlays.sorted { lhs, rhs in
                if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
                return lhs.id.description < rhs.id.description
            },
            textureSurfaces: textureSurfaces
        )
    }

    private func shouldUseNativeOverlay(surface: CanvasSurfaceDescriptor, sceneScale: CGFloat) -> Bool {
        guard surface.renderMode == .nativeOverlay else { return false }
        if let activeSurfaceID = configuration.activeSurfaceID {
            return surface.id == activeSurfaceID && sceneScale >= configuration.minimumNativeScale
        }
        return surface.isFocused && sceneScale >= configuration.minimumNativeScale
    }
}
