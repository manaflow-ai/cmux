import CMUXMobileCore
import CmuxMobileTerminal
import SwiftUI

/// Colors derived from the active terminal theme for the SwiftUI chrome around
/// the mobile terminal surface (toolbars, letterbox fill).
///
/// These follow ``GhosttyRuntime/currentTheme`` so the chrome blends with the
/// live terminal under any theme instead of flashing a hardcoded color. They
/// fall back to Monokai when no theme has been supplied.
@MainActor
let terminalPalette = TerminalPalette()

@MainActor
struct TerminalPalette {
    /// Terminal background, from the active theme.
    var background: Color { color(GhosttyRuntime.currentTheme.background) }
    /// Terminal foreground, from the active theme.
    var foreground: Color { color(GhosttyRuntime.currentTheme.foreground) }
    /// Dimmed terminal foreground, from the active theme.
    var dimForeground: Color { foreground.opacity(0.78) }

    private func color(_ hex: String) -> Color {
        guard let rgb = TerminalTheme.rgbComponents(hex) else { return .black }
        return Color(
            red: Double(rgb.red) / 255.0,
            green: Double(rgb.green) / 255.0,
            blue: Double(rgb.blue) / 255.0
        )
    }
}
