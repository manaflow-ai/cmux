import AppKit
import CmuxNextDesign
import Observation
import SwiftUI

/// Colors of the server UI, resolved by the host view in its theme scope
/// (Ghostty-derived chrome tokens). No accent color: hover and selection
/// are grays, severities are the theme's attention, danger and success. Until the host
/// resolves, the app theme's (`ThemeTokens.unresolved`), never macOS's grays.
struct ServerColors: Equatable {
    var primary = ThemeTokens.unresolved.textPrimary.swiftUIColor
    var secondary = ThemeTokens.unresolved.textSecondary.swiftUIColor
    var tertiary = ThemeTokens.unresolved.textTertiary.swiftUIColor
    var hover = ThemeTokens.unresolved.hoverFill.swiftUIColor
    var selection = ThemeTokens.unresolved.selectionFill.swiftUIColor
    var separator = ThemeTokens.unresolved.separator.swiftUIColor
    var warning = ThemeTokens.unresolved.attention.swiftUIColor
    var critical = ThemeTokens.unresolved.danger.swiftUIColor
    var ok = ThemeTokens.unresolved.success.swiftUIColor
    /// Text drawn on a `primary` fill (the Approve button).
    var onPrimary = ThemeTokens.unresolved.contentBackground.withAlpha(1).swiftUIColor

    /// A card or field fill: a faint wash of the text color, which reads on
    /// glass and on the opaque fallback alike.
    var fill: Color { primary.opacity(0.055) }

    func severity(_ severity: HealthSeverity?) -> Color {
        switch severity {
        case .critical: critical
        case .warning: warning
        case .info: secondary
        case nil: ok
        }
    }
}

extension ServerColors {
    /// The theme's colors now; call it inside the host view's `performWithTheme`.
    static func resolved() -> ServerColors {
        ServerColors(
            primary: color(Palette.textPrimary), secondary: color(Palette.textSecondary),
            tertiary: color(Palette.textTertiary), hover: color(Palette.hoverFill),
            selection: color(Palette.selectionFill), separator: color(Palette.separator),
            warning: color(Palette.attention), critical: color(Palette.danger),
            ok: color(Palette.success), onPrimary: color(Palette.textOnPrimary))
    }

    /// A static color: dynamic ones would re-resolve outside the host view's theme scope.
    private static func color(_ color: NSColor) -> Color {
        Color(nsColor: color.usingColorSpace(.sRGB) ?? color)
    }
}

@Observable
final class ServerAppearance {
    var colors = ServerColors()
}

extension EnvironmentValues {
    @Entry var serverColors = ServerColors()
    /// Border width multiplier: 0 under `appearance.borders = none`.
    @Entry var serverLineWidth: CGFloat = 1
}
