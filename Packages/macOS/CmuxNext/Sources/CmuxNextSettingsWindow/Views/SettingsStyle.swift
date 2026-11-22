import CmuxNextDesign
import SwiftUI

/// Theme colors and compact type for the Settings window. Colors are the
/// tokens of the window's theme scope (`SettingsTheme`); selection and hover
/// are gray fills.
enum SettingsStyle {
    private static var tokens: ThemeTokens { SettingsTheme.shared.tokens }
    private static func color(_ rgb: ThemeRGB) -> Color { Color(nsColor: rgb.nsColor) }

    static var text: Color { color(tokens.textPrimary) }
    static var secondary: Color { color(tokens.textSecondary) }
    static var tertiary: Color { color(tokens.textTertiary) }
    /// A tint, never an opaque fill (`ThemeTokens.cardFill`).
    static var card: Color { color(tokens.cardFill) }
    static var selection: Color { color(tokens.selectionFill) }
    static var hover: Color { color(tokens.hoverFill) }
    /// Clear under `appearance.borders` none (`Borders`).
    static var separator: Color { Borders.drawsLines ? color(tokens.separator) : .clear }
    static var danger: Color { color(tokens.danger) }
    static var attention: Color { color(tokens.attention) }
    /// Control tint (switches, sliders): the theme's focus color, never blue.
    static var tint: Color { color(tokens.focusRing) }

    static var body: Font { Font(Typography.body) }
    static var emphasized: Font { Font(Typography.bodyEmphasized) }
    static var caption: Font { Font(Typography.caption) }
    static var header: Font { Font(Typography.header) }
    static var title: Font { Font(Typography.title) }
    static var keycap: Font { Font(Typography.shortcut) }

    static var rowHeight: CGFloat { Metrics.sidebarRowHeight + Metrics.space2 }
    static var corner: CGFloat { Metrics.itemCornerRadius }
    static var cardCorner: CGFloat { Metrics.panelCornerRadius }
    /// Strength of the tint on a row a search jump or deep link opened.
    static var highlightOpacity: Double { 0.22 }
}

/// A rounded group of rows under a small heading.
struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            if let title {
                Text(title).font(SettingsStyle.header).foregroundStyle(SettingsStyle.secondary)
                    .padding(.leading, Metrics.space2)
            }
            VStack(spacing: 0) { content }
                .padding(.vertical, Metrics.space2)
                .background(SettingsStyle.card, in: RoundedRectangle(cornerRadius: SettingsStyle.cardCorner, style: .continuous))
        }
    }
}

/// Small gray button used for section actions and resets.
struct SettingsButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SettingsStyle.body)
            .foregroundStyle(destructive ? SettingsStyle.danger : SettingsStyle.text)
            .padding(.horizontal, Metrics.space4)
            .padding(.vertical, Metrics.space2)
            .background(configuration.isPressed ? SettingsStyle.selection : SettingsStyle.hover,
                        in: RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
            .contentShape(Rectangle())
    }
}
