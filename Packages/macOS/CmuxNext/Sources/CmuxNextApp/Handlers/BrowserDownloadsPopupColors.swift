import AppKit
import CmuxNextDesign

/// The Downloads popup's colors from the toolbar's theme scope (as `BookmarkPageColors`).
struct BrowserDownloadsPopupColors: Equatable {
    var primary = ThemeTokens.unresolved.textPrimary.nsColor
    var secondary = ThemeTokens.unresolved.textSecondary.nsColor
    var hover = ThemeTokens.unresolved.hoverFill.nsColor
    var separator = Borders.color(ThemeTokens.unresolved.separator.nsColor)
    var danger = ThemeTokens.unresolved.danger.nsColor

    /// Call inside `performWithTheme`. theme-scoped
    @MainActor
    static func resolve() -> BrowserDownloadsPopupColors {
        BrowserDownloadsPopupColors(primary: fixed(Palette.textPrimary), secondary: fixed(Palette.textSecondary),
                                    hover: fixed(Palette.hoverFill), separator: fixed(Palette.separator),
                                    danger: fixed(Palette.danger))
    }

    private static func fixed(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }
}
