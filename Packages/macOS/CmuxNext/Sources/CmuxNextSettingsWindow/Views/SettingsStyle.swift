import CmuxNextDesign
import SwiftUI

/// Theme colors and compact type for the Debug Settings views. Colors are the
/// tokens of the model's theme scope (``SettingsTheme``), handed down as this
/// value (`EnvironmentValues.settingsStyle`, set by ``DebugSettingsRootView``),
/// so no view below the root holds the theme; selection and hover are gray
/// fills. Type and metrics do not depend on the theme and stay static.
struct SettingsStyle: Equatable {
    /// Until a root view sets it: the app theme's (`ThemeTokens.unresolved`), never macOS's grays.
    var tokens = ThemeTokens.unresolved

    private func color(_ rgb: ThemeRGB) -> Color { Color(nsColor: rgb.nsColor) }

    var text: Color { color(tokens.textPrimary) }
    var secondary: Color { color(tokens.textSecondary) }
    var tertiary: Color { color(tokens.textTertiary) }
    /// A tint, never an opaque fill (`ThemeTokens.cardFill`).
    var card: Color { color(tokens.cardFill) }
    var selection: Color { color(tokens.selectionFill) }
    var hover: Color { color(tokens.hoverFill) }
    /// Clear under `appearance.borders` none (`Borders`).
    var separator: Color { Borders.drawsLines ? color(tokens.separator) : .clear }
    var danger: Color { color(tokens.danger) }
    var attention: Color { color(tokens.attention) }
    /// Control tint (switches, sliders): the theme's focus color, never blue.
    var tint: Color { color(tokens.focusRing) }

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

extension EnvironmentValues {
    /// The Debug Settings colors of the model's theme (``SettingsStyle``).
    ///
    /// ``DebugSettingsRootView`` must set it for its tree. A Settings card, button style or Debug
    /// control drawn under no root view gets the default: the app theme's colors, not the model's
    /// scope.
    @Entry var settingsStyle = SettingsStyle()
}

/// A rounded group of rows under a small heading.
struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content
    @Environment(\.settingsStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            if let title {
                Text(title).font(SettingsStyle.header).foregroundStyle(style.secondary)
                    .padding(.leading, Metrics.space2)
            }
            VStack(spacing: 0) { content }
                .padding(.vertical, Metrics.space2)
                .background(style.card, in: RoundedRectangle(cornerRadius: SettingsStyle.cardCorner, style: .continuous))
        }
    }
}

/// Small gray button used for section actions and resets.
struct SettingsButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.settingsStyle) private var style

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SettingsStyle.body)
            .foregroundStyle(destructive ? style.danger : style.text)
            .padding(.horizontal, Metrics.space4)
            .padding(.vertical, Metrics.space2)
            .background(configuration.isPressed ? style.selection : style.hover,
                        in: RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
            .contentShape(Rectangle())
    }
}
