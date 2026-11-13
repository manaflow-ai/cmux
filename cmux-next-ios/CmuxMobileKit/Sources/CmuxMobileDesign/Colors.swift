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
/// white) until a Mac sends its theme: with Match Mac theme on (the default) the surfaces, text,
/// fills and status colors are the Mac's (`CmuxMobileMacTheme`, ask-87d30da8e5). The accent is the user's choice (Settings > Appearance > Accent
/// color, `CmuxMobileAccentTheme`); its Default is the foreground color.
public struct CmuxMobileColors: Sendable {
    public var bg: CmuxMobileColorToken { mac(Self.stockBg) { $0.bg } }
    static let stockBg = token("#000000", "#FFFFFF")
    public var bgGrouped: CmuxMobileColorToken { mac(Self.stockBgGrouped) { $0.bg } }
    static let stockBgGrouped = token("#000000", "#F2F2F7")
    public var surface: CmuxMobileColorToken { mac(Self.stockSurface) { $0.surface } }
    static let stockSurface = token("#1C1C1E", "#FFFFFF")
    public var surfaceRaised: CmuxMobileColorToken { mac(Self.stockSurfaceRaised) { $0.surfaceRaised } }
    static let stockSurfaceRaised = token("#2C2C2E", "#F2F2F7")
    public var sheet: CmuxMobileColorToken { mac(Self.stockSheet) { $0.surface } }
    static let stockSheet = token("#1C1C1E", "#FFFFFF")
    public var bubble: CmuxMobileColorToken { mac(Self.stockBubble) { $0.surfaceRaised } }
    static let stockBubble = token("#2C2C2E", "#EDEDED")
    public var codeBg: CmuxMobileColorToken { mac(Self.stockCodeBg) { $0.codeBg } }
    static let stockCodeBg = token("#1C1C1E", "#F5F5F7")
    public var fill: CmuxMobileColorToken { mac(Self.stockFill) { $0.fill } }
    static let stockFill = token("#FFFFFF", "#000000", darkAlpha: 0.08, lightAlpha: 0.05)
    public var fillSelected: CmuxMobileColorToken { mac(Self.stockFillSelected) { $0.fillSelected } }
    static let stockFillSelected = token("#FFFFFF", "#000000", darkAlpha: 0.16, lightAlpha: 0.09)
    public var fillPressed: CmuxMobileColorToken { mac(Self.stockFillPressed) { $0.fillPressed } }
    static let stockFillPressed = token("#FFFFFF", "#000000", darkAlpha: 0.22, lightAlpha: 0.13)
    public var separator: CmuxMobileColorToken { mac(Self.stockSeparator) { $0.separator } }
    static let stockSeparator = token("#38383A", "#C6C6C8")
    public var label: CmuxMobileColorToken { mac(Self.stockLabel) { $0.label } }
    static let stockLabel = token("#FFFFFF", "#000000")
    public var label2: CmuxMobileColorToken { mac(Self.stockLabel2) { $0.label2 } }
    static let stockLabel2 = CmuxMobileColorToken(
        dark: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.6), light: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.6),
        darkHighContrast: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.7), lightHighContrast: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.75)
    )
    public var label3: CmuxMobileColorToken { mac(Self.stockLabel3) { $0.label3 } }
    static let stockLabel3 = CmuxMobileColorToken(
        dark: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.3), light: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.3),
        darkHighContrast: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.42), lightHighContrast: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.45)
    )
    /// Small print that must still read (the welcome's legal line): `label2`
    /// in dark (6.4:1 on black); darker in light, where `label2` is 3.5:1 on
    /// white and fails WCAG AA. 5.6:1 on white.
    public var legal: CmuxMobileColorToken { mac(Self.stockLegal) { $0.label2 } }
    static let stockLegal = CmuxMobileColorToken(
        dark: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.6), light: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.78),
        darkHighContrast: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.7), lightHighContrast: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.85)
    )
    /// The user's accent (`CmuxMobileAccentTheme`); read in a body, the view
    /// redraws when the choice changes.
    public var accent: CmuxMobileColorToken { CmuxMobileAccentTheme.shared.accentToken }
    public var onAccent: CmuxMobileColorToken { CmuxMobileAccentTheme.shared.onAccentToken }
    /// Always the monochrome accent, whatever the user picked: only for marks
    /// whose colour another party prescribes (Sign in with Apple is black or
    /// white).
    public var neutralAccent: CmuxMobileColorToken { CmuxMobileAccent.neutral.accent }
    public var neutralOnAccent: CmuxMobileColorToken { CmuxMobileAccent.neutral.onAccent }
    public var success: CmuxMobileColorToken { mac(Self.stockSuccess) { $0.success } }
    static let stockSuccess = token("#30D158", "#34C759")
    public var danger: CmuxMobileColorToken { mac(Self.stockDanger) { $0.danger } }
    static let stockDanger = token("#FF453A", "#FF3B30")
    /// Small error text: `danger` is 3.55:1 on white, so light mode uses the
    /// high-contrast system red (#D70015, 5.38:1). Dark #FF453A is 6.2:1 on black.
    public var dangerText: CmuxMobileColorToken { mac(Self.stockDangerText) { $0.danger } }
    static let stockDangerText = token("#FF453A", "#D70015")
    public var warning: CmuxMobileColorToken { mac(Self.stockWarning) { $0.warning } }
    static let stockWarning = token("#FFD60A", "#FFCC00")
    /// A mark with no text that must read on its own (Home's "needs you"
    /// gutter dot): at least 3:1 on the background. #C93400 is 4.9:1 on
    /// white (system orange is 2.2:1); #FF9F0A is 8.6:1 on black.
    public var needsYou: CmuxMobileColorToken { mac(Self.stockNeedsYou) { $0.warning } }
    static let stockNeedsYou = token("#FF9F0A", "#C93400")
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
    public var cardStroke: CmuxMobileColorToken { mac(Self.stockCardStroke) { $0.cardStroke } }
    static let stockCardStroke = token("#FFFFFF", "#000000", darkAlpha: 0.10, lightAlpha: 0.08)
    /// Skeleton shimmer band (SPEC 7.1).
    public var shimmerBand: CmuxMobileColorToken { mac(Self.stockShimmerBand) { $0.shimmerBand } }
    static let stockShimmerBand = token("#FFFFFF", "#000000", darkAlpha: 0.06, lightAlpha: 0.04)

    public init() {}

    /// `stock`, or the Mac theme's color for it while the chrome follows the Mac (`CmuxMobileMacTheme`).
    private func mac(_ stock: CmuxMobileColorToken, _ pick: (CmuxMobileMacPalette) -> CmuxMobileRGBA) -> CmuxMobileColorToken {
        CmuxMobileMacTheme.shared.token(stock, pick)
    }

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
