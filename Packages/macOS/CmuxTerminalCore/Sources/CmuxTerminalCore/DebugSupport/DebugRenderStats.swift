#if DEBUG
public import Foundation

/// A snapshot of a terminal surface's render and focus state, read by the debug
/// socket and the workspace focus-recovery / split-activation tests.
///
/// `GhosttySurfaceScrollView.debugRenderStats()` gathers the live Metal layer,
/// window, app-active, and first-responder reads on the main actor and captures
/// them into this pure value.
public struct DebugRenderStats {
    /// The number of terminal draws recorded for the surface.
    public let drawCount: Int
    /// The timestamp of the last terminal draw.
    public let lastDrawTime: CFTimeInterval
    /// The number of Metal drawables presented by the surface layer.
    public let metalDrawableCount: Int
    /// The timestamp of the last Metal drawable.
    public let metalLastDrawableTime: CFTimeInterval
    /// The number of layer presents recorded for the surface.
    public let presentCount: Int
    /// The timestamp of the last layer present.
    public let lastPresentTime: CFTimeInterval
    /// The concrete class name of the surface's backing layer.
    public let layerClass: String
    /// The surface layer's contents identity key.
    public let layerContentsKey: String
    /// Whether the surface is attached to a window.
    public let inWindow: Bool
    /// Whether the surface's window is the key window.
    public let windowIsKey: Bool
    /// Whether the surface's window is occlusion-visible (or key).
    public let windowOcclusionVisible: Bool
    /// Whether the application is active.
    public let appIsActive: Bool
    /// Whether the surface considers itself active.
    public let isActive: Bool
    /// Whether the surface wants focus.
    public let desiredFocus: Bool
    /// Whether the surface (or a descendant) is the first responder.
    public let isFirstResponder: Bool

    /// Captures a render-stats snapshot from already-read surface state.
    public init(
        drawCount: Int,
        lastDrawTime: CFTimeInterval,
        metalDrawableCount: Int,
        metalLastDrawableTime: CFTimeInterval,
        presentCount: Int,
        lastPresentTime: CFTimeInterval,
        layerClass: String,
        layerContentsKey: String,
        inWindow: Bool,
        windowIsKey: Bool,
        windowOcclusionVisible: Bool,
        appIsActive: Bool,
        isActive: Bool,
        desiredFocus: Bool,
        isFirstResponder: Bool
    ) {
        self.drawCount = drawCount
        self.lastDrawTime = lastDrawTime
        self.metalDrawableCount = metalDrawableCount
        self.metalLastDrawableTime = metalLastDrawableTime
        self.presentCount = presentCount
        self.lastPresentTime = lastPresentTime
        self.layerClass = layerClass
        self.layerContentsKey = layerContentsKey
        self.inWindow = inWindow
        self.windowIsKey = windowIsKey
        self.windowOcclusionVisible = windowOcclusionVisible
        self.appIsActive = appIsActive
        self.isActive = isActive
        self.desiredFocus = desiredFocus
        self.isFirstResponder = isFirstResponder
    }
}
#endif
