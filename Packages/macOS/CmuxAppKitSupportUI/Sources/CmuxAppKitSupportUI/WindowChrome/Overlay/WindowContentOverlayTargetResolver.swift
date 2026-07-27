public import AppKit

/// Resolves the AppKit insertion point for window-level overlays.
@MainActor
public struct WindowContentOverlayTargetResolver {
    private let glassEffect: any WindowGlassEffectManaging

    /// Creates a resolver using an injected glass-effect seam.
    public init(glassEffect: any WindowGlassEffectManaging) {
        self.glassEffect = glassEffect
    }

    /// Returns the glass foreground target when glass is installed, otherwise
    /// falls back to the window theme frame below `window.contentView`.
    public func installationTarget(for window: NSWindow) -> WindowContentOverlayInstallationTarget? {
        if let glassTarget = glassEffect.portalInstallationTarget(for: window) {
            return glassTarget
        }

        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else {
            return nil
        }
        return WindowContentOverlayInstallationTarget(container: themeFrame, reference: contentView)
    }
}
