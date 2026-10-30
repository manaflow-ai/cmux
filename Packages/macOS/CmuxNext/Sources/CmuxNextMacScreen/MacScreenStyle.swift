import AppKit
import CmuxNextDesign

/// Mac Screen's colors: the tokens of the tab's theme scope (Settings >
/// Appearance: theme, accent, light or dark), resolved by the view that
/// shows them (`MacScreenThemedView`) inside `performWithTheme`, and again
/// on every theme change. Until then, the app theme's
/// (`ThemeTokens.unresolved`), never macOS's grays or blue.
struct MacScreenColors: Equatable {
    /// The home page: the pane's fill, like other page tabs (clear over a window backdrop).
    var page = NSColor.clear
    /// The screen's toolbar.
    var chrome = ThemeTokens.unresolved.chromeBackground.nsColor
    /// A card over the screen (connect, connecting, failed).
    var popup = ThemeTokens.unresolved.elevatedBackground.nsColor
    /// A group of rows on the home page: a tint, never an opaque fill.
    var card = ThemeTokens.unresolved.cardFill.nsColor
    var primary = ThemeTokens.unresolved.textPrimary.nsColor
    var secondary = ThemeTokens.unresolved.textSecondary.nsColor
    var tertiary = ThemeTokens.unresolved.textTertiary.nsColor
    var hover = ThemeTokens.unresolved.hoverFill.nsColor
    var selection = ThemeTokens.unresolved.selectionFill.nsColor
    var pressed = ThemeTokens.unresolved.pressedFill.nsColor
    var separator = ThemeTokens.unresolved.separator.nsColor
    /// The theme's accent: the default button's fill, a viewer's status.
    var accent = ThemeTokens.unresolved.accent.nsColor
    var onAccent = ThemeTokens.unresolved.onAccent.nsColor
    /// A lit (on, connected) glyph: the accent, never fainter than the rest ink.
    var litGlyph = ThemeTokens.unresolved.litGlyph.nsColor
    /// Control tint (switches): the theme's focus color, never blue.
    var focus = ThemeTokens.unresolved.focusRing.nsColor
    var success = ThemeTokens.unresolved.success.nsColor
    var attention = ThemeTokens.unresolved.attention.nsColor
    var danger = ThemeTokens.unresolved.danger.nsColor
    /// Draw hairlines at all (`appearance.borders`).
    var borders = true
    var isDark = ThemeTokens.unresolved.isDark

    /// Reads the tokens of `view`'s scope.
    // theme-scoped
    @MainActor
    static func resolved(in view: NSView) -> MacScreenColors {
        let isDark = view.themeTokens.isDark
        let card = color(view.themeTokens.cardFill.nsColor)
        return view.performWithTheme {
            MacScreenColors(
                page: color(Palette.surfaceOverride(.internalPage) ?? Palette.paneFill), chrome: color(Palette.chromeBackground),
                // glass-opaque-allow: the connect, connecting and failed cards sit over the remote Mac's live picture, and the
                // host's approval panel floats over any app; glass would show moving pixels through a security prompt's text.
                popup: color(Palette.popupSurface), card: card,
                primary: color(Palette.textPrimary), secondary: color(Palette.textSecondary), tertiary: color(Palette.textTertiary),
                hover: color(Palette.hoverFill), selection: color(Palette.selectionFill), pressed: color(Palette.pressedFill),
                separator: color(Palette.separator), accent: color(Palette.accentFill), onAccent: color(Palette.onAccent), litGlyph: color(Palette.litGlyph),
                focus: color(Palette.focusRing), success: color(Palette.success), attention: color(Palette.attention),
                danger: color(Palette.danger), borders: Borders.drawsLines, isDark: isDark)
        }
    }

    /// A static color: dynamic ones would re-resolve outside the theme scope.
    private static func color(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }
}

/// A Mac Screen view that draws in its colors (`MacScreenColors`): a label,
/// a button, a card. Its themed ancestor hands it the colors once it is
/// added and again on every theme change.
@MainActor
protocol MacScreenInked: NSView {
    func apply(_ colors: MacScreenColors)
}

/// The root of a Mac Screen surface (home page, toolbar, card, approval
/// prompt) in the theme scope it sits in: its colors are resolved when it
/// moves into a window and again on every theme change (`ThemeScope` calls
/// `viewDidChangeEffectiveAppearance` on every view of the scope), and every
/// `MacScreenInked` view under it is repainted, so Settings > Appearance
/// changes show at once. It also takes the theme's light or dark, so stock
/// pieces (menus, scrollers) match. Fonts are `Typography`, which follows the
/// interface size when the surface builds its content.
@MainActor
class MacScreenThemedView: NSView {
    private(set) var colors = MacScreenColors()
    /// The colors were painted at least once (a first resolve paints even when they match the defaults).
    private var painted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    func resolveColors() {
        let colors = MacScreenColors.resolved(in: self)
        let look = NSAppearance(named: colors.isDark ? .darkAqua : .aqua)
        if appearance?.name != look?.name { appearance = look }
        guard colors != self.colors || !painted else { return }
        self.colors = colors
        painted = true
        colorsChanged()
    }

    /// The colors changed: paints this view and every inked view under it.
    func colorsChanged() {
        paint(self)
    }

    /// Paints `view` and the inked views under it in the current colors (call after adding new ones).
    func paint(_ view: NSView) {
        if view !== self, let inked = view as? any MacScreenInked { inked.apply(colors) }
        for subview in view.subviews { paint(subview) }
    }
}

/// Mac Screen's type: the design system's scale (`Typography`).
@MainActor
enum MacScreenType {
    static var title: NSFont { Typography.title }
    static var subtitle: NSFont { Typography.subtitle }
    static var body: NSFont { Typography.body }
    static var emphasized: NSFont { Typography.bodyEmphasized }
    static var header: NSFont { Typography.header }
    static var caption: NSFont { Typography.caption }
    /// A card's title.
    static var cardTitle: NSFont { Typography.system(size: Typography.subtitle.pointSize, weight: .semibold) }
    /// The View Only badge.
    static var badge: NSFont { Typography.system(size: Typography.caption.pointSize, weight: .semibold) }
    /// Numbers that change in place (the stats line).
    static var stats: NSFont { Typography.system(.monospacedDigit, size: Typography.caption.pointSize) }
    /// A key fingerprint shown as text.
    static var code: NSFont { Typography.system(.monospaced, size: Typography.caption.pointSize) }
    /// A card's or a row's glyph.
    static var glyph: NSFont { Typography.system(size: Typography.title.pointSize) }
    /// The scale's sizes now. A surface that keeps them in what it shows (read under Observation)
    /// is built again when density, the font size or the interface scale changes, as SwiftUI redrew.
    static var sizes: [CGFloat] { [title, subtitle, body, caption].map(\.pointSize) }
}
