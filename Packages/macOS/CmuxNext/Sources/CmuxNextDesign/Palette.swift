public import AppKit
import CmuxTheme
public import CmuxNextDesignTokens

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
    /// (`NSWindow.install(kind:content:scope:activeLook:)`), sidebar, panes and strip,
    /// page tabs, titlebar and docks (plans/cmux-next/windows.md).
    public static var surfaceBackground: NSColor { color(\.surfaceBackground, dynamic: PaletteDynamic.surfaceBackground) }
    /// What a page or tab view (Home, Feed, History, Tasks, Bookmarks)
    /// gives a background it must paint: the surface background, opaque,
    /// in an opaque window, and clear over a see-through one, where the
    /// window's one backdrop is the background (`WindowBackdrop`). A
    /// background image makes the window see-through at any opacity, so
    /// the backdrop is read with the scope's image. A page host's own layer
    /// paints nothing: the pane paints under it.
    public static var paneFill: NSColor {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        return WindowBackdrop.current(tokens).panesPaintBackground ? tokens.surfaceBackground.withAlpha(1).nsColor : .clear
    }
    /// A translucent scrim of the surface background for text over the
    /// window's backdrop (``ThemeTokens/legibilityScrim``).
    public static var legibilityScrim: NSColor { color(\.legibilityScrim, dynamic: PaletteDynamic.legibilityScrim) }
    /// A small translucent capsule behind a label over busy content
    /// (``ThemeTokens/capsuleScrim``).
    public static var capsuleScrim: NSColor { color(\.capsuleScrim, dynamic: PaletteDynamic.capsuleScrim) }
    /// The scrim's alpha: the most a translucent band over the window's
    /// backdrop may cover (the Home header's top fade peaks there).
    public static var legibilityScrimOpacity: CGFloat { CGFloat(ThemeTokens.legibilityScrimOpacity) }
    /// The veil's alpha over an unfocused pane (``ThemeTokens/inactivePaneDim``).
    public static var inactivePaneDim: CGFloat { CGFloat((ThemeContext.active ?? ThemeScope.app.tokens).inactivePaneDim) }
    /// Fields and toolbars that need a faint lift (omnibar, find bar).
    public static var chromeBackground: NSColor { color(\.chromeBackground, dynamic: PaletteDynamic.chromeBackground) }
    /// Floating cards: palette, hover card, editors.
    public static var elevatedBackground: NSColor { color(\.elevatedBackground, dynamic: PaletteDynamic.elevatedBackground) }
    /// The one solid surface of every overlay that carries text (palette,
    /// dialogs, hover cards, find and prompt bars, page info, popovers,
    /// tooltips): the window background lifted toward the text
    /// (``ThemeTokens/opaqueOverlayFill(lift:)``), always opaque, so no text
    /// under it shows through. Pages get the same color as
    /// `--cmux-popup-surface` (`WebTheme`).
    public static var popupSurface: NSColor {
        guard let tokens = ThemeContext.active else { return PaletteDynamic.popupSurface }
        return tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value).nsColor
    }
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
    /// The foreground layer (design/selected-is-foreground.md): what the content actually paints
    /// behind itself (``paneFill``): the surface, opaque, in an opaque window, and clear over a
    /// see-through one, where the window's one tint is the content's surface.
    public static var contentSurface: NSColor { paneFill }
    /// The selected row on the chrome (design/selected-is-foreground.md): the content's own surface,
    /// so the selected item reads as part of the foreground (Leo, 2026-11-10: "The selected tab
    /// should be white as well"). In an opaque window that is the surface, opaque, which hides the
    /// chrome's shade under the row exactly as the content does. Over a see-through window (a
    /// translucent theme, an image) the content is the window's own tint and the shade sits on that
    /// tint, so no fill over the shade can show what the content shows; only a hole in the shade can
    /// (the folder tab, `ChromeShadeHoles`). A row there keeps `selectionFill`
    /// (``ThemeTokens/selectedSurface(panesPaint:chromeShade:)``). `check-selected-surface.py` keeps every
    /// selected tab and row on these tokens.
    ///
    /// The content's surface reads as the foreground only where it contrasts with the chrome around it
    /// (``ThemeTokens/minimumSelectedContrast``). A chrome that shares the content's surface (no shade:
    /// bare, panes, flat-sidebar-line, a shared sidebar surface), or a near-black theme whose shade
    /// does not show (Builtin Dark), would lose the selection, so a row there keeps `selectionFill` too.
    public static var selectedSurface: NSColor {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let shade = Double(Metrics.mainPaneChromeShade(isDark: tokens.isDark))
        let paints = WindowBackdrop.current(tokens).panesPaintBackground
        return tokens.selectedSurface(panesPaint: paints, chromeShade: shade)?.nsColor ?? selectionFill
    }
    /// The selected folder tab (`TabCell+CornerFeet`): exactly what the content paints
    /// (``contentSurface``), since the chrome's shade is cut away under it (`ChromeShadeHoles`). Over
    /// a see-through window it is clear, and the hole shows the window's tint, as the content does.
    /// ``selectedSurface`` for a row on a panel with its own fill (`surface`: the user's sidebar background,
    /// `appearance.surfaces.sidebar`): the content's surface only where it stands out of that fill by
    /// ``ThemeTokens/minimumSelectedContrast``, else `selectionFill`. nil `surface`: the row sits on the
    /// chrome, ``selectedSurface``.
    /// A translucent `surface` is composited over the chrome it lies on (the content's surface under the
    /// chrome's shade) before the check, so the contrast is with what really shows; a colour that cannot
    /// be read in sRGB keeps `selectionFill`, which always shows.
    public static func selectedSurface(over surface: NSColor?) -> NSColor {
        let selected = selectedSurface
        guard var surface else { return selected }
        if surface.alphaComponent < 1 {
            // colour-allow: the chrome's shade, black at its alpha
            let chrome = composited(NSColor.black.withAlphaComponent(chromeShade), over: contentSurface)
            surface = composited(surface, over: chrome)
        }
        guard let a = selected.usingColorSpace(.sRGB), let b = surface.usingColorSpace(.sRGB) else { return selectionFill }
        let row = ThemeRGB(red: Double(a.redComponent), green: Double(a.greenComponent), blue: Double(a.blueComponent))
        let panel = ThemeRGB(red: Double(b.redComponent), green: Double(b.greenComponent), blue: Double(b.blueComponent))
        return row.contrast(with: panel) >= ThemeTokens.minimumSelectedContrast ? selected : selectionFill
    }
    /// `top` painted over `bottom`, in sRGB: the opaque colour a row sees under it when a panel lays a
    /// fill (a neutral group's pane, the chrome's shade) over another. `bottom` counts as opaque.
    public static func composited(_ top: NSColor, over bottom: NSColor) -> NSColor {
        guard let t = top.usingColorSpace(.sRGB), let b = bottom.usingColorSpace(.sRGB) else { return bottom }
        let a = t.alphaComponent
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x * a + y * (1 - a) }
        return NSColor(srgbRed: mix(t.redComponent, b.redComponent), green: mix(t.greenComponent, b.greenComponent),
                       blue: mix(t.blueComponent, b.blueComponent), alpha: 1)
    }
    public static var selectedFolderSurface: NSColor { contentSurface }
    /// The chrome's shade in the active theme: black at this alpha over the content's surface is the
    /// chrome (``Metrics/mainPaneChromeShade(isDark:)``). A list of tabs inside the content draws it
    /// under its rows, as a strip inside the card does, so its selected row stands out of it.
    public static var chromeShade: CGFloat {
        Metrics.mainPaneChromeShade(isDark: (ThemeContext.active ?? ThemeScope.app.tokens).isDark)
    }
    /// The folder tab reads as the selection: the content's surface stands out of the chrome around it
    /// by ``ThemeTokens/minimumSelectedContrast`` (``ThemeTokens/selectedOnChrome(_:chromeShade:)``, the
    /// rows' rule). Over a see-through window the hole shows the content's own tint, so the theme's
    /// content colour, made opaque, stands in for it. False on a chrome with no shade or a near-black
    /// theme (Builtin Dark's #000000): the selected tab keeps `selectionFill` on its pill there, over the
    /// folder, so it never disappears.
    public static var selectedFolderReads: Bool {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let shade = Double(Metrics.mainPaneChromeShade(isDark: tokens.isDark))
        return ThemeTokens.selectedOnChrome(tokens.contentSurface.withAlpha(1), chromeShade: shade) != nil
    }
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
    /// Text carets: the terminal's cursor color (`cursor-color`), else the primary text.
    public static var caret: NSColor { color(\.caret, dynamic: PaletteDynamic.caret) }

    /// The notification blue (rgb 57 130 245, sampled from the Codex app): the one color of
    /// every unread mark, the sidebar's unread dot and the pane's unread ring by default. The
    /// same hue in every theme, so an unread mark reads the same everywhere, its lightness moved
    /// per theme to 3:1 on the rows it sits on (``ThemeTokens/statusDot(_:)``).
    public static var notificationBlue: NSColor {
        dot(.notification, dynamic: NSColor(srgbRed: 57 / 255, green: 130 / 255, blue: 245 / 255, alpha: 1))
    }
    /// The sidebar's unread or new status dot: `systemBlue`'s hue, so the color means one thing in
    /// every row (Lawrence msg 11983), at 3:1 on the theme's rows (user 2026-11-03).
    public static var statusUnread: NSColor { dot(.unread, dynamic: .systemBlue) }
    /// The needs-input dot (a permission prompt, a question, waiting on the user) everywhere it
    /// shows: sidebar rows, group headers and items, and the tab strip. The theme's own yellow
    /// (``attention``, the bright dot the tab draws; Leo 2026-11-05, "it's like a yellow bright
    /// dot, which I kind of like a little bit more than the sidebar"), at 3:1 on the theme's rows.
    public static var statusAttention: NSColor { dot(.attention, dynamic: PaletteDynamic.attention) }
    /// The sidebar's error status mark (failed, stopped with an error): `systemRed`'s hue (Lawrence
    /// msg 11983), at 3:1 on the theme's rows.
    public static var statusError: NSColor { dot(.error, dynamic: .systemRed) }

    /// Inside a theme scope the mark's color in that theme; elsewhere `dynamic`.
    private static func dot(_ mark: StatusDotHue, dynamic: NSColor) -> NSColor {
        guard let tokens = ThemeContext.active else { return dynamic }
        return tokens.statusDot(mark).nsColor
    }
    /// Needs attention (agent waiting for input): the theme's ANSI yellow.
    public static var attention: NSColor { color(\.attention, dynamic: PaletteDynamic.attention) }
    /// Errors: the theme's ANSI red.
    public static var danger: NSColor { color(\.danger, dynamic: PaletteDynamic.danger) }
    /// Connected / success: the theme's ANSI green.
    public static var success: NSColor { color(\.success, dynamic: PaletteDynamic.success) }
    /// The one saturated call to action (the update circle): the theme's
    /// ANSI blue.
    public static var highlight: NSColor { color(\.highlight, dynamic: PaletteDynamic.highlight) }
    /// Whether `highlight` is the theme's own accent (its ANSI blue), not
    /// Ghostty's default palette standing in for a theme that names none.
    public static var hasThemeAccent: Bool { (ThemeContext.active ?? ThemeScope.app.tokens).hasThemeAccent }
    /// Whether the theme or `appearance.accent` names an accent, so `accentFill` has a hue; false
    /// keeps the neutral default, where `accentFill` is the primary text (``ThemeTokens/accent``).
    public static var hasChosenAccent: Bool {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        return tokens.accent != tokens.textPrimary
    }
    /// Glyphs on `highlight`.
    public static var highlightText: NSColor { color(\.highlightText, opaque: true, dynamic: PaletteDynamic.highlightText) }

    /// The theme's accent as a solid fill (``ThemeTokens/accent``): the primary text by default,
    /// the theme's own hue with `appearance.accent`. `menuHighlight` washes it.
    public static var accentFill: NSColor { color(\.accent, opaque: true, dynamic: PaletteDynamic.accentFill) }
    /// Glyphs and labels on `accentFill`, at least 4.5:1 (``ThemeTokens/onAccent``).
    public static var onAccent: NSColor { color(\.onAccent, opaque: true, dynamic: PaletteDynamic.onAccent) }
    /// A highlighted row in a cmux-drawn panel (the extensions panel): `accentFill` as a faint wash,
    /// so labels keep their own ink. Right-click menus are native and use the system highlight. A neutral theme gets a gray wash.
    /// In a scope the wash is lighter where 20% would take the label under 4.5:1 on the card
    /// (``ThemeTokens/menuHighlightShare(on:)``).
    public static var menuHighlight: NSColor {
        guard let tokens = ThemeContext.active else { return accentFill.withAlphaComponent(menuHighlightOpacity) }
        // glass-opaque-allow: the card's worst ground (its tint over the far desktop) to measure the wash on; nothing draws it.
        let card = CardMaterial(tokens, lift: ChromeTunables.opaqueOverlayLift.value, minimumOpacity: ChromeTunables.cardOpacity.value)
        let ground = card.tint.composited(over: tokens.isDark ? .white : .black)
        return tokens.accent.withAlpha(tokens.menuHighlightShare(on: ground)).nsColor
    }
    static let menuHighlightOpacity: CGFloat = 0.2

    /// The app accent. Deliberately neutral so any control that reads the
    /// accent stays in the theme's grays.
    public static var accent: NSColor { focusRing }

    /// A lit (on, chosen, done) control's glyph or label (``ThemeTokens/litGlyph``): the accent,
    /// lifted to contrast at least as much as the rest ink. Never the raw `accent`, `accentFill` or
    /// `focusRing` for a lit glyph (`no-raw-accent-lit-glyph`).
    public static var litGlyph: NSColor { color(\.litGlyph, dynamic: PaletteDynamic.litGlyph) }

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
