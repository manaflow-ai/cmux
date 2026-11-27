import AppKit
import CmuxNextDesign
import SwiftUI

/// Theme colors for the SwiftUI bookmark surfaces (the manager page, the
/// edit bubble), resolved in the host view's theme scope as static colors:
/// dynamic ones would re-resolve in SwiftUI's own appearance.
struct BookmarkPageColors: Equatable {
    var background = Color.clear
    // Until the host resolves the page's scope: the app theme, never SwiftUI's label grays.
    var primary = ThemeTokens.unresolved.textPrimary.swiftUIColor
    var secondary = ThemeTokens.unresolved.textSecondary.swiftUIColor
    var tertiary = ThemeTokens.unresolved.textTertiary.swiftUIColor
    var hover = ThemeTokens.unresolved.hoverFill.swiftUIColor
    var selection = ThemeTokens.unresolved.selectionFill.swiftUIColor
    // Through the border switch, as `Palette.separator` is: clear under `appearance.borders` none.
    var separator = Color(nsColor: Borders.color(ThemeTokens.unresolved.separator.nsColor))
    var danger = ThemeTokens.unresolved.danger.swiftUIColor

    /// Call inside `performWithTheme`. theme-scoped
    static func resolve() -> BookmarkPageColors {
        BookmarkPageColors(
            background: fixed(Palette.surfaceOverride(.internalPage) ?? Palette.paneFill), primary: fixed(Palette.textPrimary), secondary: fixed(Palette.textSecondary),
            tertiary: fixed(Palette.textTertiary), hover: fixed(Palette.hoverFill), selection: fixed(Palette.selectionFill),
            separator: fixed(Palette.separator), danger: fixed(Palette.danger))
    }

    private static func fixed(_ color: NSColor) -> Color {
        Color(nsColor: color.usingColorSpace(.sRGB) ?? color)
    }
}
