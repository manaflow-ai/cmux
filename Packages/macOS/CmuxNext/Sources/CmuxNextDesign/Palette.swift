public import AppKit

/// Chrome colors, all derived from the terminal theme (`ThemeTokens`, kept
/// live by `ThemeStore`). Each token is a dynamic `NSColor` that resolves
/// against the current theme whenever it is drawn or converted to a
/// `CGColor`, so views keep using `Palette.x` and a theme change only needs
/// a redraw (which `ThemeStore.apply` triggers).
///
/// Rule from plans/cmux-next/REWRITE.md: no blue accent. Selection, focus
/// and hover are the theme's foreground at low alpha over its background.
/// Modules never hardcode colors; add a token here instead.
public enum Palette {
    /// Window background behind chrome and content: the terminal background.
    public static let windowBackground = token(\.windowBackground)
    /// Sidebar surface: the same as the window (no panel).
    public static let sidebarBackground = token(\.sidebarBackground)
    /// Terminal and browser content area background (never glass).
    public static let contentBackground = token(\.contentBackground)
    /// Fields and toolbars that need a faint lift (omnibar, find bar).
    public static let chromeBackground = token(\.chromeBackground)
    /// Floating cards: palette, hover card, editors.
    public static let elevatedBackground = token(\.elevatedBackground)

    /// Primary text.
    public static let textPrimary = token(\.textPrimary)
    /// Secondary text, captions, inactive tab titles.
    public static let textSecondary = token(\.textSecondary)
    /// Hints, placeholders, disabled glyphs.
    public static let textTertiary = token(\.textTertiary)

    /// Hover fill for rows and tabs.
    public static let hoverFill = token(\.hoverFill)
    /// Selected row or tab fill. Replaces the system blue selection.
    public static let selectionFill = token(\.selectionFill)
    /// Multi-selected rows that are not the active one.
    public static let secondarySelectionFill = token(\.secondarySelectionFill)
    /// Pressed buttons.
    public static let pressedFill = token(\.pressedFill)
    /// Count badges.
    public static let badgeFill = token(\.badgeFill)
    /// Focus ring and keyboard focus indicator. Replaces the system blue ring.
    public static let focusRing = token(\.focusRing)
    /// Hairline separators.
    public static let separator = token(\.separator)
    /// The subtle hairline around each pane (`layout.paneBorder`).
    public static let paneBorder = token(\.paneBorder)
    /// Tint applied to glass so it takes the theme's cast.
    public static let glassTint = token(\.glassTint)
    /// Drop shadow color (opaque; the layer's shadowOpacity sets strength).
    public static let shadow = token(\.shadow)
    /// Selected text in chrome text fields.
    public static let textSelection = token(\.textSelection)

    /// Needs attention (agent waiting for input): the theme's ANSI yellow.
    public static let attention = token(\.attention)
    /// Errors: the theme's ANSI red.
    public static let danger = token(\.danger)
    /// Connected / success: the theme's ANSI green.
    public static let success = token(\.success)

    /// The app accent. Deliberately neutral so any control that reads the
    /// accent stays in the theme's grays.
    public static let accent = focusRing

    /// Text on top of `textPrimary` fills (inverted badges).
    public static let textOnPrimary = token(\.contentBackground, opaque: true)

    private static func token(_ keyPath: any KeyPath<ThemeTokens, ThemeRGB> & Sendable, opaque: Bool = false) -> NSColor {
        NSColor(name: nil) { _ in
            let rgb = ThemeSnapshot.tokens[keyPath: keyPath]
            return (opaque ? rgb.withAlpha(1) : rgb).nsColor
        }
    }
}
