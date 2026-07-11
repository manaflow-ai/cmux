import CMUXMobileCore
import Foundation
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
    /// Black or white, whichever has greater contrast against the terminal
    /// background. Used for toolbar and button glyphs.
    static var chromeForeground: Color {
        readableColor(on: TerminalThemeStore.current.background)
    }

    static func background(for theme: TerminalTheme) -> Color { color(theme.background) }
    static func chromeForeground(for theme: TerminalTheme) -> Color {
        readableColor(on: theme.background)
    }

    static func colorScheme(for theme: TerminalTheme) -> ColorScheme {
        relativeLuminance(theme.background) > 0.45 ? .light : .dark
    }

    private static func color(_ hex: String) -> Color {
        guard let rgb = TerminalTheme.rgbComponents(hex) else { return .black }
        return Color(
            red: Double(rgb.red) / 255.0,
            green: Double(rgb.green) / 255.0,
            blue: Double(rgb.blue) / 255.0
        )
    }

    private static func readableColor(on background: String) -> Color {
        relativeLuminance(background) > 0.45 ? .black : .white
    }

    private static func relativeLuminance(_ hex: String) -> Double {
        guard let rgb = TerminalTheme.rgbComponents(hex) else { return 0 }
        let channels = [rgb.red, rgb.green, rgb.blue].map { value -> Double in
            let channel = Double(value) / 255.0
            return channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
