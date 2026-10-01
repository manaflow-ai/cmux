public import AppKit

/// Chrome colors, all derived from the terminal theme (`ThemeTokens`).
///
/// Scope-aware: inside `NSView.performWithTheme` a token is a plain color of
/// that view's `ThemeScope` (room, workspace or terminal theme), so views
/// apply every color there, in a hook that runs again on a theme change.
/// Outside it a token is a dynamic color of the app theme (the Ghostty
/// config), right only for UI that belongs to no window (onboarding,
/// update sheet). `scripts/cmux-next/check-theme-scope.sh` keeps modules on
/// the scoped path.
///
/// Rule from plans/cmux-next/REWRITE.md: no blue accent. Selection, focus
/// and hover are the theme's foreground at low alpha over its background.
/// Modules never hardcode colors; add a token here instead.
public enum Palette {
    /// Window background behind chrome and content: the terminal background.
    public static var windowBackground: NSColor { color(\.windowBackground, dynamic: PaletteDynamic.windowBackground) }
    /// Sidebar surface: the same as the window (no panel).
    public static var sidebarBackground: NSColor { color(\.sidebarBackground, dynamic: PaletteDynamic.sidebarBackground) }
    /// Terminal and browser content area background (never glass).
    public static var contentBackground: NSColor { color(\.contentBackground, dynamic: PaletteDynamic.contentBackground) }
    /// A browser page before its first paint, and the views over a page
    /// (load error, sad tab): the terminal background, opaque, because a
    /// page is opaque and a stale page must not show through.
    public static var pageBackground: NSColor { color(\.contentBackground, opaque: true, dynamic: PaletteDynamic.pageBackground) }
    /// Fields and toolbars that need a faint lift (omnibar, find bar).
    public static var chromeBackground: NSColor { color(\.chromeBackground, dynamic: PaletteDynamic.chromeBackground) }
    /// Floating cards: palette, hover card, editors.
    public static var elevatedBackground: NSColor { color(\.elevatedBackground, dynamic: PaletteDynamic.elevatedBackground) }

    /// Primary text.
    public static var textPrimary: NSColor { color(\.textPrimary, dynamic: PaletteDynamic.textPrimary) }
    /// Secondary text, captions, inactive tab titles.
    public static var textSecondary: NSColor { color(\.textSecondary, dynamic: PaletteDynamic.textSecondary) }
    /// Hints, placeholders, disabled glyphs.
    public static var textTertiary: NSColor { color(\.textTertiary, dynamic: PaletteDynamic.textTertiary) }

    /// Hover fill for rows and tabs.
    public static var hoverFill: NSColor { color(\.hoverFill, dynamic: PaletteDynamic.hoverFill) }
    /// Selected row or tab fill. Replaces the system blue selection.
    public static var selectionFill: NSColor { color(\.selectionFill, dynamic: PaletteDynamic.selectionFill) }
    /// Multi-selected rows that are not the active one.
    public static var secondarySelectionFill: NSColor { color(\.secondarySelectionFill, dynamic: PaletteDynamic.secondarySelectionFill) }
    /// Pressed buttons.
    public static var pressedFill: NSColor { color(\.pressedFill, dynamic: PaletteDynamic.pressedFill) }
    /// Count badges.
    public static var badgeFill: NSColor { color(\.badgeFill, dynamic: PaletteDynamic.badgeFill) }
    /// Focus ring and keyboard focus indicator. Replaces the system blue ring.
    public static var focusRing: NSColor { color(\.focusRing, dynamic: PaletteDynamic.focusRing) }
    /// Hairline separators.
    public static var separator: NSColor { color(\.separator, dynamic: PaletteDynamic.separator) }
    /// The subtle hairline around each pane (`layout.paneBorder`).
    public static var paneBorder: NSColor { color(\.paneBorder, dynamic: PaletteDynamic.paneBorder) }
    /// Tint applied to glass so it takes the theme's cast.
    public static var glassTint: NSColor { color(\.glassTint, dynamic: PaletteDynamic.glassTint) }
    /// Drop shadow color (opaque; the layer's shadowOpacity sets strength).
    public static var shadow: NSColor { color(\.shadow, dynamic: PaletteDynamic.shadow) }
    /// Selected text in chrome text fields.
    public static var textSelection: NSColor { color(\.textSelection, dynamic: PaletteDynamic.textSelection) }

    /// Needs attention (agent waiting for input): the theme's ANSI yellow.
    public static var attention: NSColor { color(\.attention, dynamic: PaletteDynamic.attention) }
    /// Errors: the theme's ANSI red.
    public static var danger: NSColor { color(\.danger, dynamic: PaletteDynamic.danger) }
    /// Connected / success: the theme's ANSI green.
    public static var success: NSColor { color(\.success, dynamic: PaletteDynamic.success) }

    /// The app accent. Deliberately neutral so any control that reads the
    /// accent stays in the theme's grays.
    public static var accent: NSColor { focusRing }

    /// Text on top of `textPrimary` fills (inverted badges).
    public static var textOnPrimary: NSColor { color(\.contentBackground, opaque: true, dynamic: PaletteDynamic.textOnPrimary) }

    /// Inside `performWithTheme` (or `ThemeScope.perform`) a plain color of
    /// the active scope; elsewhere the dynamic app-theme color.
    private static func color(_ keyPath: KeyPath<ThemeTokens, ThemeRGB>, opaque: Bool = false, dynamic: NSColor) -> NSColor {
        guard let tokens = ThemeContext.active else { return dynamic }
        let rgb = tokens[keyPath: keyPath]
        return (opaque ? rgb.withAlpha(1) : rgb).nsColor
    }
}
