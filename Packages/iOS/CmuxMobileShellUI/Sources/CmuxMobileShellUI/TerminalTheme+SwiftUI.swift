import CMUXMobileCore
import Foundation
import SwiftUI

@MainActor
extension TerminalTheme {
    var terminalBackgroundColor: Color { background.terminalColor }
    var terminalForegroundColor: Color { foreground.terminalColor }
    var terminalChromeForegroundColor: Color { background.terminalReadableColor }
    var terminalColorScheme: ColorScheme {
        background.terminalPrefersBlackForeground ? .light : .dark
    }
}

@MainActor
private extension String {
    var terminalColor: Color {
        guard let rgb = TerminalTheme.rgbComponents(self) else { return .black }
        return Color(
            red: Double(rgb.red) / 255.0,
            green: Double(rgb.green) / 255.0,
            blue: Double(rgb.blue) / 255.0
        )
    }

    var terminalReadableColor: Color {
        terminalPrefersBlackForeground ? .black : .white
    }

    var terminalPrefersBlackForeground: Bool {
        let luminance = terminalRelativeLuminance
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return blackContrast >= whiteContrast
    }

    var terminalRelativeLuminance: Double {
        guard let rgb = TerminalTheme.rgbComponents(self) else { return 0 }
        let channels = [rgb.red, rgb.green, rgb.blue].map { value -> Double in
            let channel = Double(value) / 255.0
            return channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
