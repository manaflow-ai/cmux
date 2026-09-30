import CmuxNextDesign
import SwiftUI

/// Theme colors and compact type for the Settings window. Colors are the
/// Ghostty theme tokens (`Palette`); selection and hover are gray fills.
enum SettingsStyle {
    static var text: Color { Color(nsColor: Palette.textPrimary) }
    static var secondary: Color { Color(nsColor: Palette.textSecondary) }
    static var tertiary: Color { Color(nsColor: Palette.textTertiary) }
    static var background: Color { Color(nsColor: Palette.windowBackground) }
    static var card: Color { Color(nsColor: Palette.chromeBackground) }
    static var selection: Color { Color(nsColor: Palette.selectionFill) }
    static var hover: Color { Color(nsColor: Palette.hoverFill) }
    static var separator: Color { Color(nsColor: Palette.separator) }
    static var danger: Color { Color(nsColor: Palette.danger) }
    static var attention: Color { Color(nsColor: Palette.attention) }
    /// Control tint (switches, sliders): the theme's focus color, never blue.
    static var tint: Color { Color(nsColor: Palette.accent) }

    static var body: Font { Font(Typography.body) }
    static var emphasized: Font { Font(Typography.bodyEmphasized) }
    static var caption: Font { Font(Typography.caption) }
    static var header: Font { Font(Typography.header) }
    static var title: Font { Font(Typography.title) }
    static var keycap: Font { Font(Typography.shortcut) }

    static var rowHeight: CGFloat { Metrics.sidebarRowHeight + Metrics.space2 }
    static var corner: CGFloat { Metrics.itemCornerRadius }
    static var cardCorner: CGFloat { Metrics.panelCornerRadius }
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
