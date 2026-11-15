import AppKit
import CmuxNextDesign
import SwiftUI

/// The group info sheet's colors, resolved once in the presenting page's theme scope (a room's
/// own theme), so the SwiftUI sheet draws in it rather than in macOS's grays. The sheet's
/// background is its glass (``HomeGroupInfoSheet/surface``), not a color.
public struct HomeGroupInfoColors: Equatable, Sendable {
    // Until the presenter resolves its scope: the app theme, never SwiftUI's label grays.
    var primary = ThemeTokens.unresolved.textPrimary.swiftUIColor
    var secondary = ThemeTokens.unresolved.textSecondary.swiftUIColor
    var tertiary = ThemeTokens.unresolved.textTertiary.swiftUIColor
    var hover = ThemeTokens.unresolved.hoverFill.swiftUIColor
    var separator = ThemeTokens.unresolved.separator.swiftUIColor
    var danger = ThemeTokens.unresolved.danger.swiftUIColor
    var accent = ThemeTokens.unresolved.focusRing.swiftUIColor
    var litGlyph = ThemeTokens.unresolved.litGlyph.swiftUIColor

    public init() {}

    /// The colors of the current theme scope; call inside `performWithTheme`. theme-scoped
    @MainActor
    public static func resolve() -> HomeGroupInfoColors {
        var colors = HomeGroupInfoColors()
        colors.primary = fixed(Palette.textPrimary)
        colors.secondary = fixed(Palette.textSecondary)
        colors.tertiary = fixed(Palette.textTertiary)
        colors.hover = fixed(Palette.hoverFill)
        colors.separator = fixed(Palette.separator)
        colors.danger = fixed(Palette.danger)
        colors.accent = fixed(Palette.focusRing)
        colors.litGlyph = fixed(Palette.litGlyph)
        return colors
    }

    private static func fixed(_ color: NSColor) -> Color {
        Color(nsColor: color.usingColorSpace(.sRGB) ?? color)
    }
}
