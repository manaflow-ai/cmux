public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

extension Palette {
    /// The user's background for `kind` (`appearance.surfaces`, R55) in the
    /// active theme scope, or nil when the surface has no override and its
    /// owner keeps showing the window's one backdrop (R48). The owner paints
    /// it over the backdrop, in the hook that runs again on a theme change;
    /// `ThemeScope.setSurfaceBackgrounds` repaints every scope.
    public static func surfaceOverride(_ kind: SurfaceKind) -> NSColor? {
        if kind == .splitDivider { return splitDividerOverride }
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let scope = ThemeContext.activeScope ?? ThemeScope.app
        return scope.surfaceBackgrounds.fill(for: kind, tokens: tokens, windowTint: WindowBackdrop.currentTint(tokens))?.nsColor
    }

    /// `kind`'s override for an owner that paints it straight over the window's one tint, whose color is `sheet`
    /// (``SurfaceBackgrounds/fill(for:tokens:windowTint:overSheet:)``); nil `sheet` is ``surfaceOverride(_:)``.
    public static func surfaceOverride(_ kind: SurfaceKind, overSheet sheet: ThemeRGB?) -> NSColor? {
        if kind == .splitDivider { return splitDividerOverride }
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let scope = ThemeContext.activeScope ?? ThemeScope.app
        return scope.surfaceBackgrounds.fill(for: kind, tokens: tokens, windowTint: WindowBackdrop.currentTint(tokens),
                                             overSheet: sheet)?.nsColor
    }

    /// The split divider's line in the active scope (``SurfaceBackgrounds/dividerLine(base:)``) over
    /// ``chromeDivider``, or nil when it has no override. Under `appearance.borders` none it draws nothing, as pages
    /// do (`WebTheme.chromeDivider`): the clear divider made opaque would be a black line.
    private static var splitDividerOverride: NSColor? {
        guard Borders.drawsLines else { return nil }
        let scope = ThemeContext.activeScope ?? ThemeScope.app
        let divider = chromeDivider.usingColorSpace(.sRGB) ?? chromeDivider
        let base = ThemeRGB(red: Double(divider.redComponent), green: Double(divider.greenComponent),
                            blue: Double(divider.blueComponent), alpha: Double(divider.alphaComponent))
        return scope.surfaceBackgrounds.dividerLine(base: base)?.nsColor
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
        let scope = ThemeContext.activeScope ?? ThemeScope.app
        return scope.surfaceBackgrounds.opaqueFill(for: kind, tokens: tokens, base: baseRGB,
                                                   windowTint: WindowBackdrop.currentTint(tokens)).nsColor
    }
}
