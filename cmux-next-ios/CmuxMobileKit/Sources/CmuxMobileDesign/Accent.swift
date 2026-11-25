#if os(iOS)
import Foundation
import Observation
import SwiftUI
import UIKit

/// The chrome's accent colour: Settings > Appearance > Accent color, as in the
/// ChatGPT iOS app. Every chrome tint reads it through one token
/// (`Color.cmuxMobileAccent`, `UIColor.cmuxMobileAccent`,
/// `CmuxMobileColors.accent`) and its ink (`…OnAccent`): the agent and terminal
/// Send, armed key-row modifiers, the diff's current-match bar, the lock
/// screen's Unlock, the primary capsule, the context ring. No view hard-codes
/// a hue.
///
/// The names are the desktop's `appearance.accent` values
/// (`CmuxTheme.ThemeAccent`), so one word means the same choice on both. The
/// desktop takes a named hue from its terminal theme's ANSI slot and has two
/// more choices (`theme`, `art`) that need a terminal theme or backdrop art the
/// phone does not have; the phone uses fixed values tuned for its black and
/// white chrome. ``neutral`` ("Default") is the monochrome look: white in dark,
/// black in light.
public enum CmuxMobileAccent: String, CaseIterable, Identifiable, Sendable, Codable {
    case neutral, blue, magenta, cyan, green, yellow, red

    public var id: String { rawValue }

    /// The name Settings shows (ChatGPT's "Default" for the monochrome look).
    public var title: String {
        switch self {
        case .neutral: String(localized: "accent.neutral", defaultValue: "Default", bundle: .module)
        case .blue: String(localized: "accent.blue", defaultValue: "Blue", bundle: .module)
        case .magenta: String(localized: "accent.magenta", defaultValue: "Magenta", bundle: .module)
        case .cyan: String(localized: "accent.cyan", defaultValue: "Cyan", bundle: .module)
        case .green: String(localized: "accent.green", defaultValue: "Green", bundle: .module)
        case .yellow: String(localized: "accent.yellow", defaultValue: "Yellow", bundle: .module)
        case .red: String(localized: "accent.red", defaultValue: "Red", bundle: .module)
        }
    }

    /// The accent fill. Each hue is at least 4.5:1 against its ink
    /// (``onAccent``) and against the plain background in both appearances
    /// (`AccentThemeTests`): lighter in dark mode under black ink, darker in
    /// light mode under white ink, as the desktop fits its accent.
    public var accent: CmuxMobileColorToken {
        switch self {
        case .neutral: Self.pair("#FFFFFF", "#000000")
        case .blue: Self.pair("#409CFF", "#0064D1")
        case .magenta: Self.pair("#FF6FD8", "#B5237F")
        case .cyan: Self.pair("#5AC8FA", "#00718F")
        case .green: Self.pair("#30D158", "#1E7A34")
        case .yellow: Self.pair("#FFD60A", "#8A6500")
        case .red: Self.pair("#FF6961", "#C4251B")
        }
    }

    /// Text and glyphs on an ``accent`` fill: black in dark, white in light.
    public var onAccent: CmuxMobileColorToken { Self.pair("#000000", "#FFFFFF") }

    private static func pair(_ dark: String, _ light: String) -> CmuxMobileColorToken {
        CmuxMobileColorToken(dark: CmuxMobileRGBA(hex: dark), light: CmuxMobileRGBA(hex: light))
    }
}

/// The accent this device uses, persisted in `UserDefaults`. SwiftUI views
/// that read a token in their body redraw when it changes (Observation);
/// UIKit colors resolve it each time a trait collection resolves them.
/// Written only from the main thread (the Settings page); read anywhere.
@Observable
public final class CmuxMobileAccentTheme: @unchecked Sendable {
    public static let shared = CmuxMobileAccentTheme()
    /// The same prefix as the other device settings (`SettingsStore`).
    public static let settingKey = "cmuxMobile.settings.accent"

    @ObservationIgnored private let defaults: UserDefaults

    /// The chosen accent; an install that never chose, or a value this build
    /// does not know, is ``CmuxMobileAccent/neutral``. Choosing one stops ``followsMac``.
    public var accent: CmuxMobileAccent {
        didSet {
            defaults.set(accent.rawValue, forKey: Self.settingKey)
            followsMac = false
        }
    }
    /// Match Mac (ask-87d30da8e5): no accent chosen on this phone, so the chrome takes the Mac
    /// theme's accent while it follows the Mac (`CmuxMobileMacTheme`), else ``accent``. An install
    /// that never chose one starts here; a choice made on the phone always wins.
    public private(set) var followsMac: Bool

    @ObservationIgnored private let macTheme: CmuxMobileMacTheme

    public init(defaults: UserDefaults = .standard, macTheme: CmuxMobileMacTheme = .shared) {
        self.defaults = defaults
        self.macTheme = macTheme
        let stored = defaults.string(forKey: Self.settingKey)
        accent = stored.flatMap(CmuxMobileAccent.init(rawValue:)) ?? .neutral
        followsMac = stored == nil
    }

    /// Settings' Match Mac row: forget the phone's choice and take the Mac's accent.
    public func matchMac() {
        defaults.removeObject(forKey: Self.settingKey)
        followsMac = true
    }

    /// The Mac's accent when the accent and the chrome both follow the Mac, nil otherwise.
    private var macAccent: CmuxMobileMacPalette? { followsMac ? macTheme.palette : nil }

    /// The accent fill every chrome tint reads.
    public var accentToken: CmuxMobileColorToken {
        guard macAccent != nil else { return accent.accent }
        return macTheme.token(accent.accent) { $0.accent }
    }

    /// The ink on ``accentToken``.
    public var onAccentToken: CmuxMobileColorToken {
        guard macAccent != nil else { return accent.onAccent }
        return macTheme.token(accent.onAccent) { $0.onAccent }
    }

    /// Send's fill in the composers. A hue the person chose is Send's hue. With Default
    /// (monochrome) Send takes the theme's own blue (the Mac terminal theme's ANSI blue, or the
    /// Blue accent with no Mac theme) instead of a white disk in dark and a black one in light
    /// (Leo, 2026-11-23: the send button "has no reason to be white on whatever").
    public var sendToken: CmuxMobileColorToken {
        guard accent == .neutral else { return accentToken }
        return macTheme.token(CmuxMobileAccent.blue.accent) { palette in
            Self.themeBlue(palette) ?? (palette.isDark ? CmuxMobileAccent.blue.accent.dark : CmuxMobileAccent.blue.accent.light)
        }
    }

    /// The ink on ``sendToken``: black on a light fill, white on a dark one.
    public var onSendToken: CmuxMobileColorToken {
        guard accent == .neutral else { return onAccentToken }
        let fill = sendToken
        return CmuxMobileColorToken(dark: Self.ink(on: fill.dark), light: Self.ink(on: fill.light))
    }

    /// The terminal theme's blue for its appearance: bright blue (ANSI 12) on a dark theme,
    /// blue (ANSI 4) on a light one; nil when the theme sends no palette.
    static func themeBlue(_ palette: CmuxMobileMacPalette) -> CmuxMobileRGBA? {
        let slot = palette.isDark ? 12 : 4
        guard palette.terminalPalette.indices.contains(slot) else { return nil }
        return CmuxMobileRGBA(hex: palette.terminalPalette[slot])
    }

    /// Black or white, whichever reads on `fill` (relative luminance, WCAG).
    static func ink(on fill: CmuxMobileRGBA) -> CmuxMobileRGBA {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(fill.red) + 0.7152 * linear(fill.green) + 0.0722 * linear(fill.blue)
        // Contrast against black is (L + 0.05) / 0.05, against white 1.05 / (L + 0.05): equal at L ≈ 0.179.
        return luminance > 0.179 ? CmuxMobileRGBA(hex: "#000000") : CmuxMobileRGBA(hex: "#FFFFFF")
    }
}
#endif
