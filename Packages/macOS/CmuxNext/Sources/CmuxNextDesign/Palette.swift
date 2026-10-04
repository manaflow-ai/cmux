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
public struct Palette {
    public init() {}
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
    /// The one background of every window and surface that sits on it
    /// (``ThemeTokens/surfaceBackground``): the window
    /// (`NSWindow.install(kind:content:scope:)`), sidebar, panes and strip,
    /// page tabs, titlebar and docks (plans/cmux-next/windows.md).
    public static var surfaceBackground: NSColor { color(\.surfaceBackground, dynamic: PaletteDynamic.surfaceBackground) }
    /// What a page or tab view (Home, Feed, History, Tasks, Bookmarks)
    /// gives a background it must paint: the surface background, opaque,
    /// in an opaque window, and clear over a see-through one, where the
    /// window's one backdrop is the background (`WindowBackdrop`). A page
    /// host's own layer paints nothing: the pane paints under it.
    public static var paneFill: NSColor {
        guard let tokens = ThemeContext.active else { return surfaceBackground }
        return WindowBackdrop(tokens).panesPaintBackground ? tokens.surfaceBackground.withAlpha(1).nsColor : .clear
    }
    /// Fields and toolbars that need a faint lift (omnibar, find bar).
    public static var chromeBackground: NSColor { color(\.chromeBackground, dynamic: PaletteDynamic.chromeBackground) }
    /// Floating cards: palette, hover card, editors.
    public static var elevatedBackground: NSColor { color(\.elevatedBackground, dynamic: PaletteDynamic.elevatedBackground) }
    /// Every pane's tab strip: a shade darker than the window.
    public static var stripBackground: NSColor { color(\.stripBackground, dynamic: PaletteDynamic.stripBackground) }
    /// The sidebar's tonal step over the window backdrop.
    public static var sidebarStep: NSColor { color(\.sidebarStep, dynamic: PaletteDynamic.sidebarStep) }
    /// The strip's tonal step: a translucent shade that darkens the window
    /// backdrop to `stripBackground` (the inset sidebar panel beside the rail).
    public static var stripStep: NSColor { color(\.stripStep, dynamic: PaletteDynamic.stripStep) }

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
    /// Clear under `appearance.borders` none (`Borders`).
    public static var separator: NSColor { Borders.color(color(\.separator, dynamic: PaletteDynamic.separator)) }
    /// The subtle hairline around each pane (`layout.paneBorder`).
    public static var paneBorder: NSColor { Borders.color(color(\.paneBorder, dynamic: PaletteDynamic.paneBorder)) }
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
    /// The one saturated call to action (the update circle): the theme's
    /// ANSI blue.
    public static var highlight: NSColor { color(\.highlight, dynamic: PaletteDynamic.highlight) }
    /// Glyphs on `highlight`.
    public static var highlightText: NSColor { color(\.highlightText, opaque: true, dynamic: PaletteDynamic.highlightText) }

    /// The app accent. Deliberately neutral so any control that reads the
    /// accent stays in the theme's grays.
    public static var accent: NSColor { focusRing }

    /// Text on top of `textPrimary` fills (inverted badges).
    public static var textOnPrimary: NSColor { color(\.contentBackground, opaque: true, dynamic: PaletteDynamic.textOnPrimary) }

    /// A Debug Settings color tunable's role, in the active theme scope
    /// (the app theme outside one).
    public static func tunable(_ color: TunableColor) -> NSColor {
        color.resolve(in: ThemeContext.active ?? ThemeScope.app.tokens).nsColor
    }

    /// The pane focus ring for `settings` in the active theme scope (the app
    /// theme outside one).
    public static func paneFocusRing(_ settings: FocusRingSettings, override: CGFloat?) -> NSColor {
        settings.ringColor(in: ThemeContext.active ?? ThemeScope.app.tokens, override: override).nsColor
    }

    /// Inside `performWithTheme` (or `ThemeScope.perform`) a plain color of
    /// the active scope; elsewhere the dynamic app-theme color.
    private static func color(_ keyPath: KeyPath<ThemeTokens, ThemeRGB>, opaque: Bool = false, dynamic: NSColor) -> NSColor {
        guard let tokens = ThemeContext.active else { return dynamic }
        let rgb = tokens[keyPath: keyPath]
        return (opaque ? rgb.withAlpha(1) : rgb).nsColor
    }
}
