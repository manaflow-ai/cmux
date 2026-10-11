import AppKit
import CmuxNextDesign
import Observation
import SwiftUI

/// Colors of the panel, resolved by a host view inside its theme scope
/// (Ghostty-derived chrome tokens). No accent color: selection, hover and
/// focus are the theme's foreground at low alpha. `separator` is clear
/// under `appearance.borders = none`.
struct FeedColors: Equatable {
    var background = Color(nsColor: .windowBackgroundColor)
    var elevated = Color(nsColor: .controlBackgroundColor)
    var primary = Color(nsColor: .labelColor)
    var secondary = Color(nsColor: .secondaryLabelColor)
    var tertiary = Color(nsColor: .tertiaryLabelColor)
    var hover = Color(nsColor: .quaternaryLabelColor)
    var selection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    var pressed = Color(nsColor: .quaternaryLabelColor)
    var separator = Color(nsColor: .separatorColor)
    var attention = Color(nsColor: .systemOrange)
    var danger = Color(nsColor: .systemRed)
    var success = Color(nsColor: .systemGreen)
    var onPrimary = Color(nsColor: .windowBackgroundColor)
    var shadow = Color.black.opacity(0.2)
    /// Draw hairlines at all (`appearance.borders`).
    var borders = true
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
            borders: Borders.drawsLines)
    }

    /// A static color: dynamic ones would re-resolve outside the theme scope.
    private static func color(_ color: NSColor) -> Color {
        Color(nsColor: color.usingColorSpace(.sRGB) ?? color)
    }
}
