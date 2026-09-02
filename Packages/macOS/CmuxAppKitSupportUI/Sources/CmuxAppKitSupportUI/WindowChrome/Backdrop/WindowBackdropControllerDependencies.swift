public import AppKit

/// App-provided side effects needed by `WindowBackdropController`.
@MainActor
public protocol WindowBackdropControllerDependencies: AnyObject {
    /// Glass-effect service used to install or remove the window glass hierarchy.
    var glassEffect: any WindowGlassEffectManaging { get }

    /// Resets compositor blur for a window number.
    func resetCompositorBackgroundBlur(windowNumber: Int)

    /// Sets the compositor blur radius, in points, for a window number.
    func setCompositorBackgroundBlur(windowNumber: Int, radius: Int)

    /// Applies Ghostty's compositor blur to a transparent window when needed.
    func applyGhosttyCompositorBlurIfNeeded(to window: NSWindow)
}
