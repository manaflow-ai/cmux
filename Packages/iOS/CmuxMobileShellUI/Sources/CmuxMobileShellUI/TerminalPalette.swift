import CMUXMobileCore
import CmuxMobileTerminal
import Foundation
import Observation
import SwiftUI

/// Colors derived from the active terminal theme for the SwiftUI chrome around
/// the mobile terminal surface (toolbars, letterbox fill).
///
/// These are owned by each shell scene so one selected terminal cannot repaint
/// another scene's chrome. They fall back to Monokai when no theme has been
/// supplied.

@MainActor
@Observable
final class TerminalPalette {
    private var theme: TerminalTheme

    init(theme: TerminalTheme = GhosttyRuntime.currentTheme) {
        self.theme = theme
    }

    func setTheme(_ theme: TerminalTheme) {
        let resolved = theme.validatedOrDefault()
        guard self.theme != resolved else { return }
        self.theme = resolved
    }

    /// Terminal background, from the active theme.
    var background: Color { color(theme.background) }
    /// Terminal foreground, from the active theme.
    var foreground: Color { color(theme.foreground) }
    /// Dimmed terminal foreground, from the active theme.
    var dimForeground: Color { foreground.opacity(0.78) }
    /// Icon/text color for chrome that sits on top of the terminal background.
    var controlForeground: Color {
        isLightBackground ? .black.opacity(0.82) : .white.opacity(0.88)
    }
    /// Fill for composer and accessory controls, picked for contrast against the terminal background.
    var controlFill: Color {
        isLightBackground ? .black.opacity(0.08) : .white.opacity(0.14)
    }
    /// Stroke for composer and accessory controls, picked for contrast against the terminal background.
    var controlStroke: Color {
        isLightBackground ? .black.opacity(0.16) : .white.opacity(0.20)
    }
    /// Disabled icon/text color for chrome that sits on top of the terminal background.
    var disabledControlForeground: Color { controlForeground.opacity(0.42) }

    private var isLightBackground: Bool {
        guard let rgb = TerminalTheme.rgbComponents(theme.background) else { return false }
        func channel(_ value: Int) -> Double {
            let normalized = Double(value) / 255.0
            if normalized <= 0.03928 { return normalized / 12.92 }
            return pow((normalized + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(rgb.red) + 0.7152 * channel(rgb.green) + 0.0722 * channel(rgb.blue)
        return luminance > 0.55
    }

    private func color(_ hex: String) -> Color {
        guard let rgb = TerminalTheme.rgbComponents(hex) else { return .black }
        return Color(
            red: Double(rgb.red) / 255.0,
            green: Double(rgb.green) / 255.0,
            blue: Double(rgb.blue) / 255.0
        )
    }

}
