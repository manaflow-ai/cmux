import CMUXMobileCore
import Foundation
import SwiftUI

/// Colors derived from the active terminal theme for the SwiftUI chrome around
/// the mobile terminal surface (toolbars, letterbox fill).
///
/// Callers pass the selected surface's authoritative theme explicitly so
/// SwiftUI observes that state and repaints instead of retaining a stale global
/// palette value.
///
/// Main-actor isolated because every call site is a SwiftUI view body.
/// A caseless namespace `struct` (not an `enum`) so it is not a namespace-enum;
/// it stays internal chrome, never instantiated.
@MainActor
struct TerminalPalette {
    private init() {}

    static func background(for theme: TerminalTheme) -> Color { color(theme.background) }
    static func foreground(for theme: TerminalTheme) -> Color { color(theme.foreground) }
    static func chromeForeground(for theme: TerminalTheme) -> Color {
        readableColor(on: theme.background)
    }

    static func colorScheme(for theme: TerminalTheme) -> ColorScheme {
        prefersBlackForeground(on: theme.background) ? .light : .dark
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
        prefersBlackForeground(on: background) ? .black : .white
    }

    private static func prefersBlackForeground(on background: String) -> Bool {
        let luminance = relativeLuminance(background)
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return blackContrast >= whiteContrast
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
