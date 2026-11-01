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
    /// does not know, is ``CmuxMobileAccent/neutral``.
    public var accent: CmuxMobileAccent {
        didSet { defaults.set(accent.rawValue, forKey: Self.settingKey) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accent = defaults.string(forKey: Self.settingKey).flatMap(CmuxMobileAccent.init(rawValue:)) ?? .neutral
    }
}
#endif
