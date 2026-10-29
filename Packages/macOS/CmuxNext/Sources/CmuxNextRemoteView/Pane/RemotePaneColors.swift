import AppKit
import CmuxNextDesign

/// Chrome colors of the pane, resolved by the pane view inside its theme
/// scope and handed to every subview. No blue: selection and hover are the
/// foreground at low alpha; the path dot uses success / attention; the
/// upstream indicator uses the theme accent. Until the pane resolves, the app theme's
/// (`ThemeTokens.unresolved`), never macOS's grays.
struct RemotePaneColors: Equatable {
    var background = ThemeTokens.unresolved.contentBackground.nsColor
    var textPrimary = ThemeTokens.unresolved.textPrimary.nsColor
    var textSecondary = ThemeTokens.unresolved.textSecondary.nsColor
    var textTertiary = ThemeTokens.unresolved.textTertiary.nsColor
    var hoverFill = ThemeTokens.unresolved.hoverFill.nsColor
    var selectionFill = ThemeTokens.unresolved.selectionFill.nsColor
    var badgeFill = ThemeTokens.unresolved.badgeFill.nsColor
    var separator = ThemeTokens.unresolved.separator.nsColor
    var attention = ThemeTokens.unresolved.attention.nsColor
    var danger = ThemeTokens.unresolved.danger.nsColor
    var success = ThemeTokens.unresolved.success.nsColor
    /// The Ghostty theme accent (`Palette.accent`), never the system blue.
    var accent = ThemeTokens.unresolved.accent.nsColor
    /// A lit button's label (`Palette.litGlyph`): the accent, never fainter than at rest.
    var litGlyph = ThemeTokens.unresolved.litGlyph.nsColor
    var drawsBorders = true

    /// Reads the chrome tokens; callers run it inside `performWithTheme`.
    // theme-scoped
    static func resolved() -> RemotePaneColors {
        RemotePaneColors(
            background: plain(Palette.contentBackground),
            textPrimary: plain(Palette.textPrimary), textSecondary: plain(Palette.textSecondary),
            textTertiary: plain(Palette.textTertiary), hoverFill: plain(Palette.hoverFill),
            selectionFill: plain(Palette.selectionFill), badgeFill: plain(Palette.badgeFill),
            separator: plain(Palette.separator), attention: plain(Palette.attention),
            danger: plain(Palette.danger), success: plain(Palette.success), accent: plain(Palette.accent),
            litGlyph: plain(Palette.litGlyph),
            drawsBorders: Borders.drawsLines)
    }

    /// The dot color of a path: green direct, amber through the cloud or relay.
    func dot(for path: RemotePath?) -> NSColor {
        switch path {
        case .direct: success
        case .viaCloudRegion, .relayed, .compatibility: attention
        case nil: textTertiary
        }
    }

    /// A static sRGB color: a dynamic one would re-resolve outside the scope.
    private static func plain(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }
}
