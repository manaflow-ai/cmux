import Foundation
import Observation

// Shared Sleepy Mode preferences. Lives in the settings package so the
// Preferences "Sleepy Mode" section can bind to it directly; the app's
// renderer and controller read the same store.

public enum SleepyTheme: String, CaseIterable, Identifiable, Sendable {
    case cmux, blossom, mint, mono, custom
    public var id: String { rawValue }
}

public enum SleepyMascot: String, CaseIterable, Identifiable, Sendable {
    case cmux, cat, ghost, logoFace
    public var id: String { rawValue }
}

public enum SleepyGlow: String, CaseIterable, Identifiable, Sendable {
    case black, midnight, cmux, aurora, sunset, ocean, custom
    public var id: String { rawValue }
}

/// Default custom colors (matched to the cmux theme so "Custom" starts familiar).
public enum SleepyCustomDefaults {
    public static let face = "E0EDFF"
    public static let cap = "5CD6FF"
    public static let blush = "FF99B5"
    public static let ink = "333D6B"
    public static let logo = "6BDEFF"
    public static let background = "060812"
}

/// Immutable snapshot of the user's Sleepy Mode preferences, read fresh each
/// frame by the renderer so settings changes preview live.
public struct SleepyModeConfig: Equatable, Sendable {
    public var theme: SleepyTheme = .cmux
    public var mascot: SleepyMascot = .cmux
    public var glow: SleepyGlow = .black
    public var showMoon = true
    public var showStars = true
    public var showZs = true
    public var showClock = true
    public var showStatus = true
    public var showPets = true

    // Custom colors (used when theme == .custom / glow == .custom). Hex "RRGGBB".
    public var customFace = SleepyCustomDefaults.face
    public var customCap = SleepyCustomDefaults.cap
    public var customBlush = SleepyCustomDefaults.blush
    public var customInk = SleepyCustomDefaults.ink
    public var customLogo = SleepyCustomDefaults.logo
    public var customBackground = SleepyCustomDefaults.background

    public init() {}
}

/// Persisted, observable Sleepy Mode preferences. The renderer reads
/// `snapshot()` fresh each animation frame, so changing any value updates the
/// full-screen overlay immediately; the settings section binds to the same
/// store via `@Bindable`. Accessed only on the main thread in practice.
@Observable
public final class SleepyModeSettingsStore {
    nonisolated(unsafe) public static let shared = SleepyModeSettingsStore()

    public var theme: SleepyTheme { didSet { persist(theme.rawValue, Keys.theme) } }
    public var mascot: SleepyMascot { didSet { persist(mascot.rawValue, Keys.mascot) } }
    public var glow: SleepyGlow { didSet { persist(glow.rawValue, Keys.glow) } }
    public var showMoon: Bool { didSet { persist(showMoon, Keys.showMoon) } }
    public var showStars: Bool { didSet { persist(showStars, Keys.showStars) } }
    public var showZs: Bool { didSet { persist(showZs, Keys.showZs) } }
    public var showClock: Bool { didSet { persist(showClock, Keys.showClock) } }
    public var showStatus: Bool { didSet { persist(showStatus, Keys.showStatus) } }
    public var showPets: Bool { didSet { persist(showPets, Keys.showPets) } }

    public var customFace: String { didSet { persist(customFace, Keys.customFace) } }
    public var customCap: String { didSet { persist(customCap, Keys.customCap) } }
    public var customBlush: String { didSet { persist(customBlush, Keys.customBlush) } }
    public var customInk: String { didSet { persist(customInk, Keys.customInk) } }
    public var customLogo: String { didSet { persist(customLogo, Keys.customLogo) } }
    public var customBackground: String { didSet { persist(customBackground, Keys.customBackground) } }

    private let defaults: UserDefaults

    private enum Keys {
        static let theme = "sleepyMode.theme"
        static let mascot = "sleepyMode.mascot"
        static let glow = "sleepyMode.glow"
        static let showMoon = "sleepyMode.showMoon"
        static let showStars = "sleepyMode.showStars"
        static let showZs = "sleepyMode.showZs"
        static let showClock = "sleepyMode.showClock"
        static let showStatus = "sleepyMode.showStatus"
        static let showPets = "sleepyMode.showPets"
        static let customFace = "sleepyMode.customFace"
        static let customCap = "sleepyMode.customCap"
        static let customBlush = "sleepyMode.customBlush"
        static let customInk = "sleepyMode.customInk"
        static let customLogo = "sleepyMode.customLogo"
        static let customBackground = "sleepyMode.customBackground"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let fallback = SleepyModeConfig()
        theme = (defaults.string(forKey: Keys.theme)).flatMap(SleepyTheme.init(rawValue:)) ?? fallback.theme
        mascot = (defaults.string(forKey: Keys.mascot)).flatMap(SleepyMascot.init(rawValue:)) ?? fallback.mascot
        glow = (defaults.string(forKey: Keys.glow)).flatMap(SleepyGlow.init(rawValue:)) ?? fallback.glow
        showMoon = defaults.object(forKey: Keys.showMoon) as? Bool ?? fallback.showMoon
        showStars = defaults.object(forKey: Keys.showStars) as? Bool ?? fallback.showStars
        showZs = defaults.object(forKey: Keys.showZs) as? Bool ?? fallback.showZs
        showClock = defaults.object(forKey: Keys.showClock) as? Bool ?? fallback.showClock
        showStatus = defaults.object(forKey: Keys.showStatus) as? Bool ?? fallback.showStatus
        showPets = defaults.object(forKey: Keys.showPets) as? Bool ?? fallback.showPets
        customFace = defaults.string(forKey: Keys.customFace) ?? fallback.customFace
        customCap = defaults.string(forKey: Keys.customCap) ?? fallback.customCap
        customBlush = defaults.string(forKey: Keys.customBlush) ?? fallback.customBlush
        customInk = defaults.string(forKey: Keys.customInk) ?? fallback.customInk
        customLogo = defaults.string(forKey: Keys.customLogo) ?? fallback.customLogo
        customBackground = defaults.string(forKey: Keys.customBackground) ?? fallback.customBackground
    }

    public func snapshot() -> SleepyModeConfig {
        var config = SleepyModeConfig()
        config.theme = theme
        config.mascot = mascot
        config.glow = glow
        config.showMoon = showMoon
        config.showStars = showStars
        config.showZs = showZs
        config.showClock = showClock
        config.showStatus = showStatus
        config.showPets = showPets
        config.customFace = customFace
        config.customCap = customCap
        config.customBlush = customBlush
        config.customInk = customInk
        config.customLogo = customLogo
        config.customBackground = customBackground
        return config
    }

    private func persist(_ value: String, _ key: String) { defaults.set(value, forKey: key) }
    private func persist(_ value: Bool, _ key: String) { defaults.set(value, forKey: key) }
}
