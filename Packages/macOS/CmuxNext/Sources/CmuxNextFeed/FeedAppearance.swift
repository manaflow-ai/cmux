import AppKit
import CmuxNextDesign
import Observation
import SwiftUI

/// Colors of the panel, resolved by a host view inside its theme scope
/// (Ghostty-derived chrome tokens). No accent color: selection, hover and
/// focus are the theme's foreground at low alpha. `separator` is clear
/// under `appearance.borders = none`. Until a host resolves, the app theme's
/// (`ThemeTokens.unresolved`), never macOS's grays.
struct FeedColors: Equatable {
    var background = ThemeTokens.unresolved.contentBackground.withAlpha(1).swiftUIColor
    var elevated = ThemeTokens.unresolved.elevatedBackground.swiftUIColor
    var primary = ThemeTokens.unresolved.textPrimary.swiftUIColor
    var secondary = ThemeTokens.unresolved.textSecondary.swiftUIColor
    var tertiary = ThemeTokens.unresolved.textTertiary.swiftUIColor
    var hover = ThemeTokens.unresolved.hoverFill.swiftUIColor
    var selection = ThemeTokens.unresolved.selectionFill.swiftUIColor
    var pressed = ThemeTokens.unresolved.pressedFill.swiftUIColor
    var separator = ThemeTokens.unresolved.separator.swiftUIColor
    var attention = ThemeTokens.unresolved.attention.swiftUIColor
    var danger = ThemeTokens.unresolved.danger.swiftUIColor
    var success = ThemeTokens.unresolved.success.swiftUIColor
    var onPrimary = ThemeTokens.unresolved.contentBackground.withAlpha(1).swiftUIColor
    var shadow = ThemeTokens.unresolved.shadow.swiftUIColor
    /// Draw hairlines at all (`appearance.borders`).
    var borders = true
    /// The same colors as AppKit values, for the AppKit reports basket.
    var basket = ReportsBasketColors()
}

@Observable
final class FeedAppearance {
    var colors = FeedColors()
}

extension EnvironmentValues {
    @Entry var feedColors = FeedColors()
}

extension FeedColors {
    /// Reads the chrome tokens; callers run it inside `performWithTheme`.
    // theme-scoped
    static func resolved(background: NSColor) -> FeedColors {
        FeedColors(
            background: color(background), elevated: color(Palette.elevatedBackground),
            primary: color(Palette.textPrimary), secondary: color(Palette.textSecondary),
            tertiary: color(Palette.textTertiary), hover: color(Palette.hoverFill),
            selection: color(Palette.selectionFill), pressed: color(Palette.pressedFill),
            separator: color(Palette.separator), attention: color(Palette.attention),
            danger: color(Palette.danger), success: color(Palette.success),
            onPrimary: color(Palette.textOnPrimary), shadow: color(Palette.shadow),
            borders: Borders.drawsLines, basket: .resolved(background: background))
    }

    /// A static color: dynamic ones would re-resolve outside the theme scope.
    private static func color(_ color: NSColor) -> Color {
        Color(nsColor: color.usingColorSpace(.sRGB) ?? color)
    }
}

/// Puts the AppKit ``ReportsBasketView`` in the SwiftUI panel, with the panel's colors. It goes
/// when the panel is AppKit (plans/cmux-next/no-swiftui-DESIGN.md, Feed).
struct ReportsBasketHost: NSViewRepresentable {
    let model: FeedModel
    let onReply: (@MainActor (ReportReply) async -> Bool)?
    @Environment(\.feedColors) private var colors

    func makeNSView(context: Context) -> ReportsBasketView {
        let view = ReportsBasketView(model: model, onReply: onReply)
        view.apply(colors.basket)
        return view
    }

    func updateNSView(_ view: ReportsBasketView, context: Context) {
        view.apply(colors.basket)
    }
}
