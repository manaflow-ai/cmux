#if os(iOS)
import SwiftUI
import UIKit

/// One semantic color with a dark, light and optional Increase Contrast value
/// (SPEC section 2.1). Usable directly as a SwiftUI `ShapeStyle`, as a `Color`,
/// or as a dynamic `UIColor` for UIKit containers.
public struct CmuxMobileColorToken: ShapeStyle, Sendable, Hashable {
    public let dark: CmuxMobileRGBA
    public let light: CmuxMobileRGBA
    public let darkHighContrast: CmuxMobileRGBA?
    public let lightHighContrast: CmuxMobileRGBA?

    public init(dark: CmuxMobileRGBA, light: CmuxMobileRGBA, darkHighContrast: CmuxMobileRGBA? = nil, lightHighContrast: CmuxMobileRGBA? = nil) {
        self.dark = dark
        self.light = light
        self.darkHighContrast = darkHighContrast
        self.lightHighContrast = lightHighContrast
    }

    /// A dynamic `UIColor` that resolves per trait collection.
    public var uiColor: UIColor {
        let dark = dark, light = light, darkHC = darkHighContrast, lightHC = lightHighContrast
        return UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let highContrast = traits.accessibilityContrast == .high
            let value = isDark ? (highContrast ? darkHC ?? dark : dark) : (highContrast ? lightHC ?? light : light)
            return value.uiColor
        }
    }

    /// The token as a SwiftUI `Color` (dynamic).
    public var color: Color { Color(uiColor: uiColor) }

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let isDark = environment.colorScheme == .dark
        let highContrast = environment.colorSchemeContrast == .increased
        let value = isDark ? (highContrast ? darkHighContrast ?? dark : dark) : (highContrast ? lightHighContrast ?? light : light)
        return Color.Resolved(colorSpace: .sRGB, red: Float(value.red), green: Float(value.green), blue: Float(value.blue), opacity: Float(value.alpha))
    }
}

/// An sRGB color value.
public struct CmuxMobileRGBA: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBB` with an optional alpha multiplier. Invalid input yields mid gray.
    public init(hex: String, alpha: Double = 1) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        guard digits.count == 6, Scanner(string: digits).scanHexInt64(&value) else {
            self.init(red: 0.5, green: 0.5, blue: 0.5, alpha: alpha)
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    public var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
}

private func token(_ dark: String, _ light: String, darkAlpha: Double = 1, lightAlpha: Double = 1) -> CmuxMobileColorToken {
    CmuxMobileColorToken(dark: CmuxMobileRGBA(hex: dark, alpha: darkAlpha), light: CmuxMobileRGBA(hex: light, alpha: lightAlpha))
}

/// The semantic palette from SPEC section 2.1. Chrome is neutral (true black /
/// white). The accent is the user's choice (Settings > Appearance > Accent
/// color, `CmuxMobileAccentTheme`); its Default is the foreground color.
public struct CmuxMobileColors: Sendable {
    public var bg = token("#000000", "#FFFFFF")
    public var bgGrouped = token("#000000", "#F2F2F7")
    public var surface = token("#1C1C1E", "#FFFFFF")
    public var surfaceRaised = token("#2C2C2E", "#F2F2F7")
    public var sheet = token("#1C1C1E", "#FFFFFF")
    public var bubble = token("#2C2C2E", "#EDEDED")
    public var codeBg = token("#1C1C1E", "#F5F5F7")
    public var fill = token("#FFFFFF", "#000000", darkAlpha: 0.08, lightAlpha: 0.05)
    public var fillSelected = token("#FFFFFF", "#000000", darkAlpha: 0.16, lightAlpha: 0.09)
    public var fillPressed = token("#FFFFFF", "#000000", darkAlpha: 0.22, lightAlpha: 0.13)
    public var separator = token("#38383A", "#C6C6C8")
    public var label = token("#FFFFFF", "#000000")
    public var label2 = CmuxMobileColorToken(
        dark: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.6), light: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.6),
        darkHighContrast: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.7), lightHighContrast: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.75)
    )
    public var label3 = CmuxMobileColorToken(
        dark: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.3), light: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.3),
        darkHighContrast: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.42), lightHighContrast: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.45)
    )
    /// Small print that must still read (the welcome's legal line): `label2`
    /// in dark (6.4:1 on black); darker in light, where `label2` is 3.5:1 on
    /// white and fails WCAG AA. 5.6:1 on white.
    public var legal = CmuxMobileColorToken(
        dark: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.6), light: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.78),
        darkHighContrast: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.7), lightHighContrast: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.85)
    )
    /// The user's accent (`CmuxMobileAccentTheme`); read in a body, the view
    /// redraws when the choice changes.
    public var accent: CmuxMobileColorToken { CmuxMobileAccentTheme.shared.accent.accent }
    public var onAccent: CmuxMobileColorToken { CmuxMobileAccentTheme.shared.accent.onAccent }
    /// Always the monochrome accent, whatever the user picked: only for marks
    /// whose colour another party prescribes (Sign in with Apple is black or
    /// white).
    public var neutralAccent: CmuxMobileColorToken { CmuxMobileAccent.neutral.accent }
    public var neutralOnAccent: CmuxMobileColorToken { CmuxMobileAccent.neutral.onAccent }
    public var success = token("#30D158", "#34C759")
    public var danger = token("#FF453A", "#FF3B30")
    /// Small error text: `danger` is 3.55:1 on white, so light mode uses the
    /// high-contrast system red (#D70015, 5.38:1). Dark #FF453A is 6.2:1 on black.
    public var dangerText = token("#FF453A", "#D70015")
    public var warning = token("#FFD60A", "#FFCC00")
    /// A mark with no text that must read on its own (Home's "needs you"
    /// gutter dot): at least 3:1 on the background. #C93400 is 4.9:1 on
    /// white (system orange is 2.2:1); #FF9F0A is 8.6:1 on black.
    public var needsYou = token("#FF9F0A", "#C93400")
    public var offline = token("#48484A", "#C7C7CC")
    public var diffAddText = token("#3FB950", "#1A7F37")
    public var diffDelText = token("#F85149", "#CF222E")
    public var diffAddRow = token("#2EA043", "#DAFBE1", darkAlpha: 0.15)
    public var diffDelRow = token("#F85149", "#FFEBE9", darkAlpha: 0.15)
    public var diffAddWord = token("#2EA043", "#ACEEBB", darkAlpha: 0.4)
    public var diffDelWord = token("#F85149", "#FFCECB", darkAlpha: 0.4)
    public var diffHunkBg = token("#FFFFFF", "#DDF4FF", darkAlpha: 0.04, lightAlpha: 0.5)
    public var scrim = token("#000000", "#000000", darkAlpha: 0.4, lightAlpha: 0.2)
    /// The pushed card's hairline stroke while the sidebar is open (SPEC 3.3).
    public var cardStroke = token("#FFFFFF", "#000000", darkAlpha: 0.10, lightAlpha: 0.08)
    /// Skeleton shimmer band (SPEC 7.1).
    public var shimmerBand = token("#FFFFFF", "#000000", darkAlpha: 0.06, lightAlpha: 0.04)

    public init() {}

    /// The 13-color team palette (SPEC 3.4). Stored as the dark value.
    public var teamPalette: [CmuxMobileTeamColor] {
        [
            CmuxMobileTeamColor(name: "Red", dark: "#FF453A", light: "#FF3B30"),
            CmuxMobileTeamColor(name: "Orange", dark: "#FF9F0A", light: "#FF9500"),
            CmuxMobileTeamColor(name: "Yellow", dark: "#FFD60A", light: "#FFCC00"),
            CmuxMobileTeamColor(name: "Green", dark: "#30D158", light: "#34C759"),
            CmuxMobileTeamColor(name: "Mint", dark: "#63E6E2", light: "#00C7BE"),
            CmuxMobileTeamColor(name: "Teal", dark: "#40CBE0", light: "#30B0C7"),
            CmuxMobileTeamColor(name: "Cyan", dark: "#64D2FF", light: "#32ADE6"),
            CmuxMobileTeamColor(name: "Blue", dark: "#0A84FF", light: "#007AFF"),
            CmuxMobileTeamColor(name: "Indigo", dark: "#5E5CE6", light: "#5856D6"),
            CmuxMobileTeamColor(name: "Purple", dark: "#BF5AF2", light: "#AF52DE"),
            CmuxMobileTeamColor(name: "Pink", dark: "#FF375F", light: "#FF2D55"),
            CmuxMobileTeamColor(name: "Brown", dark: "#AC8E68", light: "#A2845E"),
            CmuxMobileTeamColor(name: "Gray", dark: "#8E8E93", light: "#8E8E93"),
        ]
    }

    /// The dynamic team color for a stored `#RRGGBB` (dark) value. Unknown values
    /// are used as-is in both appearances.
    public func team(_ storedHex: String) -> CmuxMobileColorToken {
        if let match = teamPalette.first(where: { $0.dark.caseInsensitiveCompare(storedHex) == .orderedSame }) {
            return match.token
        }
        return token(storedHex, storedHex)
    }
}

/// A named team color pair.
public struct CmuxMobileTeamColor: Sendable, Hashable, Identifiable {
    public let name: String
    public let dark: String
    public let light: String

    public var id: String { dark }
    public var token: CmuxMobileColorToken { CmuxMobileColorToken(dark: CmuxMobileRGBA(hex: dark), light: CmuxMobileRGBA(hex: light)) }
}

extension Color {
    /// `#RRGGBB` or `#RRGGBBAA`. Invalid input yields gray.
    public init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        guard Scanner(string: digits).scanHexInt64(&value), digits.count == 6 || digits.count == 8 else {
            self = .gray
            return
        }
        let hasAlpha = digits.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
#endif
