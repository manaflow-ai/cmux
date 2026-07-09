public import AppKit
public import WebKit

extension WKWebView {
    /// Forces the web view's effective `NSAppearance` to dark or light.
    ///
    /// WebKit's `prefers-color-scheme` media query reflects the `WKWebView`'s
    /// effective `NSAppearance`. Forcing it here lets a host panel decouple its
    /// rendered content from the system appearance and follow an app-chosen
    /// color scheme. The appearance object is only reassigned when it actually
    /// differs, so repeated calls during view updates are cheap and idempotent.
    public func applyForcedAppearance(isDark: Bool) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if self.appearance !== appearance {
            self.appearance = appearance
        }
    }

    /// Fills the web view with a solid background color across both its
    /// over-scroll (`underPageBackgroundColor`) surface and its backing layer.
    ///
    /// The backing layer is marked opaque only when the color is effectively
    /// fully opaque (alpha ≥ 0.999), preserving translucency when a
    /// semi-transparent color is supplied.
    public func applyBackgroundFill(_ backgroundColor: NSColor) {
        underPageBackgroundColor = backgroundColor
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }
}
