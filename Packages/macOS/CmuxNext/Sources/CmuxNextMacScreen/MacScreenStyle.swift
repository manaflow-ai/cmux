import AppKit
import CmuxNextDesign
import Observation
import SwiftUI

/// Mac Screen's colors: the tokens of the tab's theme scope (Settings >
/// Appearance: theme, accent, light or dark), resolved by the hosting view
/// that shows them (`MacScreenHostingView`) inside `performWithTheme`, and
/// again on every theme change. Until then, the app theme's
/// (`ThemeTokens.unresolved`), never macOS's grays or blue.
struct MacScreenColors: Equatable {
    /// The home page: the pane's fill, like other page tabs (clear over a window backdrop).
    var page = Color.clear
    /// The screen's toolbar.
    var chrome = ThemeTokens.unresolved.chromeBackground.swiftUIColor
    /// A card over the screen (connect, connecting, failed).
    var popup = ThemeTokens.unresolved.elevatedBackground.swiftUIColor
    /// A group of rows on the home page: a tint, never an opaque fill.
    var card = ThemeTokens.unresolved.cardFill.swiftUIColor
    var primary = ThemeTokens.unresolved.textPrimary.swiftUIColor
    var secondary = ThemeTokens.unresolved.textSecondary.swiftUIColor
    var tertiary = ThemeTokens.unresolved.textTertiary.swiftUIColor
    var hover = ThemeTokens.unresolved.hoverFill.swiftUIColor
    var selection = ThemeTokens.unresolved.selectionFill.swiftUIColor
    var pressed = ThemeTokens.unresolved.pressedFill.swiftUIColor
    var separator = ThemeTokens.unresolved.separator.swiftUIColor
    /// The theme's accent: the default button's fill, a viewer's status.
    var accent = ThemeTokens.unresolved.accent.swiftUIColor
    var onAccent = ThemeTokens.unresolved.onAccent.swiftUIColor
    /// Control tint (switches): the theme's focus color, never blue.
    var focus = ThemeTokens.unresolved.focusRing.swiftUIColor
    var success = ThemeTokens.unresolved.success.swiftUIColor
    var attention = ThemeTokens.unresolved.attention.swiftUIColor
    var danger = ThemeTokens.unresolved.danger.swiftUIColor
    /// Draw hairlines at all (`appearance.borders`).
    var borders = true
    var isDark = ThemeTokens.unresolved.isDark

    /// Reads the tokens of `view`'s scope.
    // theme-scoped
    @MainActor
    static func resolved(in view: NSView) -> MacScreenColors {
        let isDark = view.themeTokens.isDark
        let card = view.themeTokens.cardFill.swiftUIColor
        return view.performWithTheme {
            MacScreenColors(
                page: color(Palette.surfaceOverride(.internalPage) ?? Palette.paneFill), chrome: color(Palette.chromeBackground),
                popup: color(Palette.popupSurface), card: card,
                primary: color(Palette.textPrimary), secondary: color(Palette.textSecondary), tertiary: color(Palette.textTertiary),
                hover: color(Palette.hoverFill), selection: color(Palette.selectionFill), pressed: color(Palette.pressedFill),
                separator: color(Palette.separator), accent: color(Palette.accentFill), onAccent: color(Palette.onAccent),
                focus: color(Palette.focusRing), success: color(Palette.success), attention: color(Palette.attention),
                danger: color(Palette.danger), borders: Borders.drawsLines, isDark: isDark)
        }
    }

    /// A static color: dynamic ones would re-resolve outside the theme scope.
    private static func color(_ color: NSColor) -> Color {
        Color(nsColor: color.usingColorSpace(.sRGB) ?? color)
    }
}

@Observable
final class MacScreenAppearance {
    var colors = MacScreenColors()
}

extension EnvironmentValues {
    @Entry var macScreenColors = MacScreenColors()
}

/// Gives `content` the appearance's colors, and its light or dark.
struct MacScreenThemed<Content: View>: View {
    let appearance: MacScreenAppearance
    let content: Content

    var body: some View {
        content
            .environment(\.macScreenColors, appearance.colors)
            .environment(\.colorScheme, appearance.colors.isDark ? .dark : .light)
    }
}

/// Hosts a Mac Screen view in the theme scope it sits in: its colors are
/// resolved when it moves into a window and again on every theme change
/// (`ThemeScope` calls `viewDidChangeEffectiveAppearance` on every view of
/// the scope), so Settings > Appearance changes show at once. Fonts are
/// `Typography`, which follows the interface size live.
final class MacScreenHostingView<Content: View>: NSHostingView<MacScreenThemed<Content>> {
    let themeAppearance: MacScreenAppearance

    init(_ content: Content) {
        let appearance = MacScreenAppearance()
        themeAppearance = appearance
        super.init(rootView: MacScreenThemed(appearance: appearance, content: content))
    }

    @available(*, unavailable)
    @MainActor required init(rootView: MacScreenThemed<Content>) { fatalError("init(rootView:) is not supported") }

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
        if themeAppearance.colors != colors { themeAppearance.colors = colors }
    }
}

/// Mac Screen's type: the design system's scale (`Typography`).
struct MacScreenType {
    static var title: Font { Font(Typography.title) }
    static var subtitle: Font { Font(Typography.subtitle) }
    static var body: Font { Font(Typography.body) }
    static var emphasized: Font { Font(Typography.bodyEmphasized) }
    static var header: Font { Font(Typography.header) }
    static var caption: Font { Font(Typography.caption) }
    /// Numbers that change in place (the stats line).
    static var stats: Font { Font(Typography.caption).monospacedDigit() }
    /// A link shown as text.
    static var code: Font { Font(NSFont.monospacedSystemFont(ofSize: Typography.caption.pointSize, weight: .regular)) }
    /// A card's or a row's glyph.
    static var glyph: Font { Font(NSFont.systemFont(ofSize: Typography.title.pointSize, weight: .regular)) }
}

/// Buttons in the theme: `primary` is the accent fill (the default
/// action), `plain` a faint fill, `destructive` the danger color, `icon`
/// a bare glyph that fills on hover.
struct MacScreenButtonStyle: ButtonStyle {
    enum Role {
        case primary
        case plain
        case destructive
        case icon
    }

    var role: Role = .plain
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        MacScreenButtonBody(label: configuration.label, isPressed: configuration.isPressed, role: role, compact: compact)
    }
}

/// The button's look; a view so it can keep its hover state.
private struct MacScreenButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let role: MacScreenButtonStyle.Role
    let compact: Bool
    @Environment(\.macScreenColors) private var colors
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        label
            .font(role == .primary ? MacScreenType.emphasized : MacScreenType.body)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, role == .icon ? Metrics.space1 : (compact ? Metrics.space3 : Metrics.space4))
            .frame(minWidth: role == .icon ? Metrics.space6 : nil, minHeight: compact || role == .icon ? 22 : 26)
            .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous).fill(fill))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch role {
        case .primary: colors.onAccent
        case .destructive: colors.danger
        case .plain: colors.primary
        case .icon: hovering ? colors.primary : colors.secondary
        }
    }

    private var fill: Color {
        switch role {
        case .primary: colors.accent.opacity(isPressed ? 0.75 : (hovering ? 0.9 : 1))
        case .icon: isPressed ? colors.pressed : (hovering && isEnabled ? colors.hover : .clear)
        case .plain, .destructive: isPressed ? colors.pressed : (hovering ? colors.selection : colors.hover)
        }
    }
}

extension View {
    /// A menu whose label draws in the theme's ink (not AppKit's borderless
    /// button). Menu labels render through AppKit, which keeps images and text.
    func macScreenMenu(_ color: Color) -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).foregroundStyle(color).fixedSize()
    }
}
