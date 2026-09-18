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
    /// uses a sibling of the window content view without changing its ownership.
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

    /// Returns an in-content target for WebKit's native hover event delivery.
    ///
    /// WebKit on macOS 27 does not deliver native mouse movement to the page
    /// when hosted beside `window.contentView`. A browser portal can instead
    /// be added directly to that view, leaving SwiftUI's content root, layout,
    /// sidebar, and titlebar safe-area contract intact.
    public func browserInstallationTarget(for window: NSWindow) -> WindowContentOverlayInstallationTarget? {
        if let glassTarget = glassEffect.portalInstallationTarget(for: window) {
            return glassTarget
        }
        guard let contentView = window.contentView else { return nil }
        if let browserHost = Self.descendant(
            in: contentView,
            matching: WindowContentOverlayBrowserHostView.identifier
        ) {
            return WindowContentOverlayInstallationTarget(container: browserHost, reference: browserHost)
        }
        guard let themeFrame = contentView.superview else { return nil }
        return WindowContentOverlayInstallationTarget(container: themeFrame, reference: contentView)
    }

    private static func descendant(in root: NSView, matching identifier: NSUserInterfaceItemIdentifier) -> NSView? {
        if root.identifier == identifier { return root }
        for subview in root.subviews {
            if let match = descendant(in: subview, matching: identifier) { return match }
        }
        return nil
    }
}
