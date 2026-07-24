import CmuxSettingsUI
import SwiftUI

// MARK: - Palettes

enum SleepyPalette {
    static func colors(for config: SleepyModeConfig) -> [Character: Color] {
        switch config.theme {
        case .custom:
            let face = Color(sleepyHex: config.customFace)
            let cap = Color(sleepyHex: config.customCap)
            let logo = Color(sleepyHex: config.customLogo)
            return [
                "O": face,
                "o": face.sleepyDarkened(0.22),
                "P": cap,
                "p": cap.sleepyDarkened(0.32),
                "W": .white,
                "B": Color(sleepyHex: config.customBlush),
                "H": logo.sleepyLightened(0.30),
                "C": logo,
                "c": logo.sleepyDarkened(0.30),
                "Y": Color(red: 1.0, green: 0.93, blue: 0.70),
            ]
        case .cmux:
            return base(
                face: Color(red: 0.88, green: 0.93, blue: 1.0),
                faceShade: Color(red: 0.69, green: 0.77, blue: 0.93),
                cap: Color(red: 0.36, green: 0.84, blue: 1.0),
                capShade: Color(red: 0.18, green: 0.55, blue: 0.86)
            )
        case .blossom:
            return base(
                face: Color(red: 1.0, green: 0.94, blue: 0.96),
                faceShade: Color(red: 0.95, green: 0.78, blue: 0.85),
                cap: Color(red: 1.0, green: 0.55, blue: 0.72),
                capShade: Color(red: 0.85, green: 0.34, blue: 0.55)
            )
        case .mint:
            return base(
                face: Color(red: 0.90, green: 1.0, blue: 0.95),
                faceShade: Color(red: 0.70, green: 0.90, blue: 0.80),
                cap: Color(red: 0.35, green: 0.86, blue: 0.66),
                capShade: Color(red: 0.18, green: 0.62, blue: 0.46)
            )
        case .mono:
            return base(
                face: Color(white: 0.92),
                faceShade: Color(white: 0.66),
                cap: Color(white: 0.55),
                capShade: Color(white: 0.36)
            )
        }
    }

    /// Shared accents (blush, pom-pom, moon, and the always-cyan cmux logo).
    private static func base(face: Color, faceShade: Color, cap: Color, capShade: Color) -> [Character: Color] {
        [
            "O": face,
            "o": faceShade,
            "P": cap,
            "p": capShade,
            "W": .white,
            "B": Color(red: 1.0, green: 0.60, blue: 0.71),
            "H": Color(red: 0.74, green: 0.96, blue: 1.0),   // cmux logo highlight
            "C": Color(red: 0.42, green: 0.87, blue: 1.0),
            "c": Color(red: 0.16, green: 0.52, blue: 0.93),
            "Y": Color(red: 1.0, green: 0.93, blue: 0.70),
        ]
    }

    static func ink(for config: SleepyModeConfig) -> Color {
        switch config.theme {
        case .custom: return Color(sleepyHex: config.customInk)
        case .mono: return Color(white: 0.18)
        default: return Color(red: 0.20, green: 0.24, blue: 0.42)
        }
    }

    static func glowColors(for config: SleepyModeConfig) -> [Color] {
        switch config.glow {
        case .custom:
            let bg = Color(sleepyHex: config.customBackground)
            return [bg, bg]
        case .black:
            return [.black, .black]
        case .midnight:
            return [Color(red: 0.06, green: 0.07, blue: 0.14), Color(red: 0.01, green: 0.01, blue: 0.03)]
        case .cmux:
            return [Color(red: 0.08, green: 0.16, blue: 0.28), Color(red: 0.01, green: 0.02, blue: 0.06)]
        case .aurora:
            return [Color(red: 0.07, green: 0.20, blue: 0.16), Color(red: 0.03, green: 0.04, blue: 0.10)]
        case .sunset:
            return [Color(red: 0.22, green: 0.10, blue: 0.16), Color(red: 0.05, green: 0.02, blue: 0.06)]
        case .ocean:
            return [Color(red: 0.05, green: 0.12, blue: 0.22), Color(red: 0.01, green: 0.02, blue: 0.05)]
        }
    }
}
