import AppKit
import CmuxHomeRender
import CmuxNextDesign

/// The render core's palette from the cmux-next theme. The sent bubble is
/// the theme's accent (its ANSI blue, `Palette.highlight`; Lawrence
/// 2026-10-05), with white or dark text by contrast (`HomePalette.themed`);
/// a theme that names no palette takes MessagesLab's measured blue. Users
/// may pick another accent; `accentOverride` carries it.
enum HomeThemePalette {
    /// MessagesLab's measured sent-bubble blue (catalyst Fixture.outgoing).
    static let messagesBlue = NSColor(srgbRed: 2 / 255, green: 132 / 255, blue: 254 / 255, alpha: 1)

    /// Whether the sent bubble is MessagesLab's blue: no chosen accent and a
    /// theme without its own accent. Callers run inside `performWithTheme`.
    static func usesMessagesBlueInScope(accentOverride: NSColor? = nil) -> Bool { // theme-scoped
        accentOverride == nil && !Palette.hasThemeAccent
    }

    /// Resolves the tokens; callers run inside `performWithTheme` (theme-scoped).
    static func resolveInScope(active: Bool, accentOverride: NSColor? = nil) -> HomePalette { // theme-scoped
        let accent = accentOverride ?? (Palette.hasThemeAccent ? Palette.highlight : messagesBlue)
        let theme = HomePalette.Theme(
            background: color(Palette.windowBackground, opaque: true),
            foreground: color(Palette.textPrimary, opaque: true),
            accent: color(accent, opaque: true),
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
