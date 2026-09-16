public import AppKit

/// Resolves the AppKit insertion point for window-level overlays.
@MainActor
public struct WindowContentOverlayTargetResolver {
    private let glassEffect: any WindowGlassEffectManaging

    /// Creates a resolver using an injected glass-effect seam.
    public init(glassEffect: any WindowGlassEffectManaging) {
        self.glassEffect = glassEffect
    }

    /// Returns a shared overlay target inside the window's content hierarchy.
    ///
    /// Without glass, installs one content root that retains the original
    /// content view as the reference below the overlays. WebKit on macOS 27
    /// receives native mouse movement but does not deliver it to the page when
    /// hosted beside `window.contentView` in AppKit's private theme frame.
    public func installationTarget(for window: NSWindow) -> WindowContentOverlayInstallationTarget? {
        if let glassTarget = glassEffect.portalInstallationTarget(for: window) {
            return glassTarget
        }

        guard let contentView = window.contentView else { return nil }
        let root: WindowContentOverlayRootView
        if let installedRoot = contentView as? WindowContentOverlayRootView {
            root = installedRoot
        } else {
            root = WindowContentOverlayRootView(contentView: contentView)
            root.install(in: window)
        }
        return WindowContentOverlayInstallationTarget(
            container: root,
            reference: root.originalContentView
        )
    }
}
