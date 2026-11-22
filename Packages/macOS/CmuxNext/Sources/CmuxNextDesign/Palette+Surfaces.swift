public import AppKit
import CmuxTheme

extension Palette {
    /// The user's background for `kind` (`appearance.surfaces`, R55) in the
    /// active theme scope, or nil when the surface has no override and its
    /// owner keeps showing the window's one backdrop (R48). The owner paints
    /// it over the backdrop, in the hook that runs again on a theme change;
    /// `ThemeScope.setSurfaceBackgrounds` repaints every scope.
    public static func surfaceOverride(_ kind: SurfaceKind) -> NSColor? {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        return ThemeScope.app.surfaceBackgrounds.fill(for: kind, tokens: tokens)?.nsColor
    }

    /// `kind`'s background: its override, else `fallback` (what the owner
    /// painted before overrides existed).
    public static func fill(for kind: SurfaceKind, default fallback: @autoclosure () -> NSColor) -> NSColor {
        surfaceOverride(kind) ?? fallback()
    }

    /// `kind`'s override laid over `base` as one opaque color, for owners
    /// that must stay opaque (a docked column hides what scrolls under it);
    /// `base` without an override.
    public static func opaqueFill(for kind: SurfaceKind, base: NSColor) -> NSColor {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        guard let rgb = base.usingColorSpace(.sRGB) else { return base }
        let baseRGB = ThemeRGB(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
        return ThemeScope.app.surfaceBackgrounds.opaqueFill(for: kind, tokens: tokens, base: baseRGB).nsColor
    }
}
