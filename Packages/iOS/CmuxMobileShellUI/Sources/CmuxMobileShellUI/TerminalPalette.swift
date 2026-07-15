import CMUXMobileCore
import SwiftUI

/// Colors derived from the active terminal theme for the SwiftUI chrome around
/// the mobile terminal surface (toolbars, letterbox fill).
///
/// These follow ``TerminalThemeStore/current`` so the chrome blends with the
/// live terminal under any theme instead of flashing a hardcoded color. They
/// fall back to Monokai when no theme has been supplied.
///
/// Main-actor isolated because it reads the `@MainActor` ``TerminalThemeStore``;
/// every call site is a SwiftUI view body, which is already on the main actor.
/// A caseless namespace `struct` (not an `enum`) so it is not a namespace-enum;
/// it stays internal chrome, never instantiated.
@MainActor
struct TerminalPalette {
    private init() {}

    /// Terminal background, from the active theme.
    static var background: Color { color(TerminalThemeStore.current.background) }
    /// Terminal foreground, from the active theme.
    static var foreground: Color { color(TerminalThemeStore.current.foreground) }
    /// Dimmed terminal foreground, from the active theme.
    static var dimForeground: Color { foreground.opacity(0.78) }

    private static func color(_ hex: String) -> Color {
        guard let rgb = TerminalTheme.rgbComponents(hex) else { return .black }
        return Color(
            red: Double(rgb.red) / 255.0,
            green: Double(rgb.green) / 255.0,
            blue: Double(rgb.blue) / 255.0
        )
    }
}
