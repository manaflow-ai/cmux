#if os(iOS)
import SwiftUI
import UIKit

/// One semantic color with a dark, light and optional Increase Contrast value
/// (SPEC section 2.1). Usable directly as a SwiftUI `ShapeStyle`, as a `Color`,
/// or as a dynamic `UIColor` for UIKit containers.
///
/// A token read from ``CmuxMobileColors`` carries its ``role``: its `uiColor`
/// then resolves the role in the current appearance (``CmuxMobileAppearance``)
/// each time UIKit resolves it, so a UIKit view that kept the color follows a
/// theme change (the window's ``CmuxMobileAppearanceRevisionTrait`` makes it
/// resolve again). The role is not part of the token's value (`==`).
public struct CmuxMobileColorToken: ShapeStyle, Sendable, Hashable {
    public let dark: CmuxMobileRGBA
    public let light: CmuxMobileRGBA
    public let darkHighContrast: CmuxMobileRGBA?
    public let lightHighContrast: CmuxMobileRGBA?
    /// The palette role this value was read for (nil: a fixed color).
    public let role: CmuxMobileColorRole?

    public init(dark: CmuxMobileRGBA, light: CmuxMobileRGBA, darkHighContrast: CmuxMobileRGBA? = nil, lightHighContrast: CmuxMobileRGBA? = nil) {
        self.init(dark: dark, light: light, darkHighContrast: darkHighContrast, lightHighContrast: lightHighContrast, role: nil)
    }

    init(dark: CmuxMobileRGBA, light: CmuxMobileRGBA, darkHighContrast: CmuxMobileRGBA?, lightHighContrast: CmuxMobileRGBA?, role: CmuxMobileColorRole?) {
        self.dark = dark
        self.light = light
        self.darkHighContrast = darkHighContrast
        self.lightHighContrast = lightHighContrast
        self.role = role
    }

    /// The same value read for `role`.
    func reading(_ role: CmuxMobileColorRole) -> CmuxMobileColorToken {
        CmuxMobileColorToken(dark: dark, light: light, darkHighContrast: darkHighContrast, lightHighContrast: lightHighContrast, role: role)
    }

    /// The same colors at `alpha` times their opacity.
    public func opacity(_ alpha: Double) -> CmuxMobileColorToken {
        func scaled(_ c: CmuxMobileRGBA?) -> CmuxMobileRGBA? { c.map { CmuxMobileRGBA(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha * alpha) } }
        return CmuxMobileColorToken(dark: scaled(dark)!, light: scaled(light)!, darkHighContrast: scaled(darkHighContrast), lightHighContrast: scaled(lightHighContrast))
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.dark == b.dark && a.light == b.light && a.darkHighContrast == b.darkHighContrast && a.lightHighContrast == b.lightHighContrast
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(dark)
        hasher.combine(light)
        hasher.combine(darkHighContrast)
        hasher.combine(lightHighContrast)
    }

    /// The value for `traits`, from this token's own colors.
    public func value(dark isDark: Bool, highContrast: Bool) -> CmuxMobileRGBA {
        isDark ? (highContrast ? darkHighContrast ?? dark : dark) : (highContrast ? lightHighContrast ?? light : light)
    }

    /// A dynamic `UIColor` that resolves per trait collection (and, for a
    /// palette role, per current appearance).
    public var uiColor: UIColor {
        if let role {
            return UIColor { traits in
                CmuxMobileAppearance.shared.token(role)
                    .value(dark: traits.userInterfaceStyle == .dark, highContrast: traits.accessibilityContrast == .high).uiColor
            }
        }
        let token = self
        return UIColor { traits in
            token.value(dark: traits.userInterfaceStyle == .dark, highContrast: traits.accessibilityContrast == .high).uiColor
        }
    }

    /// The token as a SwiftUI `Color` (dynamic).
    public var color: Color { Color(uiColor: uiColor) }

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let value = value(dark: environment.colorScheme == .dark, highContrast: environment.colorSchemeContrast == .increased)
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

/// Every themable color of the phone (SPEC 2.1): what ``CmuxMobileColors``,
/// `Color.cmuxMobile…` and `UIColor.cmuxMobile…` read. With no Mac theme
/// (never connected, or the phone's own neutral choice) each role is its
/// built-in neutral value (``CmuxMobilePaletteValues/neutral``); with one, it
/// is derived from the Mac's snapshot by the Mac's own code
/// (``CmuxMobileAppearanceResolver``).
public enum CmuxMobileColorRole: Int, CaseIterable, Sendable, Hashable {
    case bg, bgGrouped, surface, surfaceRaised, sheet, card, bubble, onBubble, codeBg
    case fill, fillSelected, fillPressed, separator
    case label, label2, label3, legal
    case accent, onAccent
    case success, danger, dangerText, warning, needsYou, offline
    case diffAddText, diffDelText, diffAddRow, diffDelRow, diffAddWord, diffDelWord, diffAddGutter, diffDelGutter, diffHunkBg
    case syntaxKeyword, syntaxString, syntaxNumber, syntaxType, syntaxFunction, syntaxComment
    case scrim, cardStroke, shimmerBand
    /// The sidebar's own shade (two-tone and `sidebarSurface: separate`); clear otherwise.
    case sidebarShade
    /// Behind terminal content (the terminal theme's background).
    case terminalBackground
}

/// One value per ``CmuxMobileColorRole``.
public struct CmuxMobilePaletteValues: Sendable, Equatable {
    private var values: [CmuxMobileColorToken]

    public init(_ value: (CmuxMobileColorRole) -> CmuxMobileColorToken) {
        values = CmuxMobileColorRole.allCases.map(value)
    }

    public subscript(role: CmuxMobileColorRole) -> CmuxMobileColorToken {
        get { values[role.rawValue] }
        set { values[role.rawValue] = newValue }
    }

    /// The built-in neutral look (SPEC 2.1): true black and white chrome. Its
    /// accent is the phone's Accent color choice (`CmuxMobileAccentTheme`),
    /// read when a token is.
    public static let neutral = CmuxMobilePaletteValues { role in
        switch role {
        case .bg: token("#000000", "#FFFFFF")
        case .bgGrouped: token("#000000", "#F2F2F7")
        case .surface: token("#1C1C1E", "#FFFFFF")
        case .surfaceRaised: token("#2C2C2E", "#F2F2F7")
        case .sheet: token("#1C1C1E", "#FFFFFF")
        /// Card background on `bg` (permission, question, plan cards).
        case .card: token("#1C1C1E", "#F2F2F7")
        case .bubble: token("#2C2C2E", "#EDEDED")
        case .onBubble: token("#FFFFFF", "#000000")
        case .codeBg: token("#1C1C1E", "#F5F5F7")
        case .fill: token("#FFFFFF", "#000000", darkAlpha: 0.08, lightAlpha: 0.05)
        case .fillSelected: token("#FFFFFF", "#000000", darkAlpha: 0.16, lightAlpha: 0.09)
        case .fillPressed: token("#FFFFFF", "#000000", darkAlpha: 0.22, lightAlpha: 0.13)
        case .separator: token("#38383A", "#C6C6C8")
        case .label: token("#FFFFFF", "#000000")
        case .label2: CmuxMobileColorToken(
            dark: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.6), light: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.6),
            darkHighContrast: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.7), lightHighContrast: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.75))
        case .label3: CmuxMobileColorToken(
            dark: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.3), light: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.3),
            darkHighContrast: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.42), lightHighContrast: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.45))
        /// Small print that must still read (the welcome's legal line): `label2`
        /// in dark (6.4:1 on black); darker in light, where `label2` is 3.5:1 on
        /// white and fails WCAG AA. 5.6:1 on white.
        case .legal: CmuxMobileColorToken(
            dark: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.6), light: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.78),
            darkHighContrast: CmuxMobileRGBA(hex: "#EBEBF5", alpha: 0.7), lightHighContrast: CmuxMobileRGBA(hex: "#3C3C43", alpha: 0.85))
        // Read from `CmuxMobileAccentTheme` instead (CmuxMobileAppearance.token).
        case .accent: CmuxMobileAccent.neutral.accent
        case .onAccent: CmuxMobileAccent.neutral.onAccent
        case .success: token("#30D158", "#34C759")
        case .danger: token("#FF453A", "#FF3B30")
        /// Small error text: `danger` is 3.55:1 on white, so light mode uses the
        /// high-contrast system red (#D70015, 5.38:1). Dark #FF453A is 6.2:1 on black.
        case .dangerText: token("#FF453A", "#D70015")
        case .warning: token("#FFD60A", "#FFCC00")
        /// A mark with no text that must read on its own (Home's "needs you"
        /// gutter dot): at least 3:1 on the background.
        case .needsYou: token("#FF9F0A", "#C93400")
        case .offline: token("#48484A", "#C7C7CC")
        case .diffAddText: token("#3FB950", "#1A7F37")
        case .diffDelText: token("#F85149", "#CF222E")
        case .diffAddRow: token("#2EA043", "#DAFBE1", darkAlpha: 0.15)
        case .diffDelRow: token("#F85149", "#FFEBE9", darkAlpha: 0.15)
        case .diffAddWord: token("#2EA043", "#ACEEBB", darkAlpha: 0.4)
        case .diffDelWord: token("#F85149", "#FFCECB", darkAlpha: 0.4)
        case .diffAddGutter: token("#2EA043", "#CCFFD8", darkAlpha: 0.30)
        case .diffDelGutter: token("#F85149", "#FFD7D5", darkAlpha: 0.30)
        case .diffHunkBg: token("#FFFFFF", "#DDF4FF", darkAlpha: 0.04, lightAlpha: 0.5)
        /// Syntax palette (SPEC 2.1 fallback: Apple system colors pushed toward readable on `codeBg`).
        case .syntaxKeyword: token("#FF7AB2", "#AD3DA4")
        case .syntaxString: token("#FC6A5D", "#D12F1B")
        case .syntaxNumber: token("#D9C97C", "#272AD8")
        case .syntaxType: token("#5DD8FF", "#0B4F79")
        case .syntaxFunction: token("#67B7A4", "#326D74")
        case .syntaxComment: token("#7F8C98", "#707F8C")
        case .scrim: token("#000000", "#000000", darkAlpha: 0.4, lightAlpha: 0.2)
        /// The pushed card's hairline stroke while the sidebar is open (SPEC 3.3).
        case .cardStroke: token("#FFFFFF", "#000000", darkAlpha: 0.10, lightAlpha: 0.08)
        /// Skeleton shimmer band (SPEC 7.1).
        case .shimmerBand: token("#FFFFFF", "#000000", darkAlpha: 0.06, lightAlpha: 0.04)
        case .sidebarShade: token("#000000", "#000000", darkAlpha: 0, lightAlpha: 0)
        /// Terminal theme: true black like the app chrome (the terminal's own light look is black too).
        case .terminalBackground: token("#000000", "#000000")
        }
    }
}

/// The semantic palette from SPEC section 2.1, read from the current
/// appearance (``CmuxMobileAppearance``): the built-in neutral look (true
/// black / white chrome, the phone's Accent color), or the Mac's theme. Read
/// in a view's body, the view redraws when the appearance changes.
public struct CmuxMobileColors: Sendable {
    private func live(_ role: CmuxMobileColorRole) -> CmuxMobileColorToken {
        CmuxMobileAppearance.shared.token(role).reading(role)
    }

    public var bg: CmuxMobileColorToken { live(.bg) }
    public var bgGrouped: CmuxMobileColorToken { live(.bgGrouped) }
    public var surface: CmuxMobileColorToken { live(.surface) }
    public var surfaceRaised: CmuxMobileColorToken { live(.surfaceRaised) }
    public var sheet: CmuxMobileColorToken { live(.sheet) }
    public var card: CmuxMobileColorToken { live(.card) }
    public var bubble: CmuxMobileColorToken { live(.bubble) }
    /// Text on ``bubble`` (the person's own messages).
    public var onBubble: CmuxMobileColorToken { live(.onBubble) }
    public var codeBg: CmuxMobileColorToken { live(.codeBg) }
    public var fill: CmuxMobileColorToken { live(.fill) }
    public var fillSelected: CmuxMobileColorToken { live(.fillSelected) }
    public var fillPressed: CmuxMobileColorToken { live(.fillPressed) }
    public var separator: CmuxMobileColorToken { live(.separator) }
    public var label: CmuxMobileColorToken { live(.label) }
    public var label2: CmuxMobileColorToken { live(.label2) }
    public var label3: CmuxMobileColorToken { live(.label3) }
    public var legal: CmuxMobileColorToken { live(.legal) }
    /// The accent: the phone's choice (`CmuxMobileAccentTheme`) in the neutral
    /// look, the Mac's (`appearance.accent`, derived from its theme) under a theme.
    public var accent: CmuxMobileColorToken { live(.accent) }
    public var onAccent: CmuxMobileColorToken { live(.onAccent) }
    /// Always the monochrome accent, whatever the user picked: only for marks
    /// whose colour another party prescribes (Sign in with Apple is black or
    /// white).
    public var neutralAccent: CmuxMobileColorToken { CmuxMobileAccent.neutral.accent }
    public var neutralOnAccent: CmuxMobileColorToken { CmuxMobileAccent.neutral.onAccent }
    public var success: CmuxMobileColorToken { live(.success) }
    public var danger: CmuxMobileColorToken { live(.danger) }
    public var dangerText: CmuxMobileColorToken { live(.dangerText) }
    public var warning: CmuxMobileColorToken { live(.warning) }
    public var needsYou: CmuxMobileColorToken { live(.needsYou) }
    public var offline: CmuxMobileColorToken { live(.offline) }
    public var diffAddText: CmuxMobileColorToken { live(.diffAddText) }
    public var diffDelText: CmuxMobileColorToken { live(.diffDelText) }
    public var diffAddRow: CmuxMobileColorToken { live(.diffAddRow) }
    public var diffDelRow: CmuxMobileColorToken { live(.diffDelRow) }
    public var diffAddWord: CmuxMobileColorToken { live(.diffAddWord) }
    public var diffDelWord: CmuxMobileColorToken { live(.diffDelWord) }
    public var diffHunkBg: CmuxMobileColorToken { live(.diffHunkBg) }
    public var scrim: CmuxMobileColorToken { live(.scrim) }
    public var cardStroke: CmuxMobileColorToken { live(.cardStroke) }
    public var shimmerBand: CmuxMobileColorToken { live(.shimmerBand) }
    /// The sidebar's own shade over the window (two-tone); clear when it shares the window's surface.
    public var sidebarShade: CmuxMobileColorToken { live(.sidebarShade) }
    public var terminalBackground: CmuxMobileColorToken { live(.terminalBackground) }

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
