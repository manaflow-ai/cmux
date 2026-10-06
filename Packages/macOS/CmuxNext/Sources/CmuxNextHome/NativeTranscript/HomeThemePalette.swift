import AppKit
import CmuxHomeRender
import CmuxNextDesign

/// The render core's palette from the cmux-next theme: the sent bubble uses
/// the theme's text colour (as the Home transcript does), never a fixed blue.
/// Users may pick another accent; `accentOverride` carries it.
enum HomeThemePalette {
    /// Resolves the tokens; callers run inside `performWithTheme` (theme-scoped).
    static func resolveInScope(active: Bool, accentOverride: NSColor? = nil) -> HomePalette { // theme-scoped
        let theme = HomePalette.Theme(
            background: color(Palette.windowBackground, opaque: true),
            foreground: color(Palette.textPrimary, opaque: true),
            accent: color(accentOverride ?? Palette.textPrimary, opaque: true),
            failure: color(Palette.danger, opaque: true))
        var palette = HomePalette.themed(theme, active: active)
        // One window background (plans/cmux-next/windows.md): the scene
        // paints the pane's fill, never a tint of its own, active or not,
        // unless the user set Home's background (`appearance.surfaces.home`).
        palette.background = color(Palette.fill(for: .home, default: Palette.paneFill), opaque: false)
        return palette
    }

    private static func color(_ c: NSColor, opaque: Bool) -> HomeColor {
        let s = c.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        return HomeColor(red: s.redComponent, green: s.greenComponent, blue: s.blueComponent, alpha: opaque ? 1 : s.alphaComponent)
    }
}
