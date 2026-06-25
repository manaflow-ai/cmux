import Foundation
import Observation

// Shared Sleepy Mode preferences. Lives in the settings package so the
// Preferences "Sleepy Mode" section can bind to it directly; the app's
// renderer and controller read the same store.

public enum SleepyTheme: String, CaseIterable, Identifiable, Sendable {
    case cmux, blossom, mint, mono
    public var id: String { rawValue }
}

public enum SleepyMascot: String, CaseIterable, Identifiable, Sendable {
    case cmux, cat, ghost, logoFace
    public var id: String { rawValue }
}

public enum SleepyGlow: String, CaseIterable, Identifiable, Sendable {
    case black, midnight, cmux, aurora, sunset, ocean
    public var id: String { rawValue }
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
    public var requireAuth = true

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
    public var requireAuth: Bool { didSet { persist(requireAuth, Keys.requireAuth) } }

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
        static let requireAuth = "sleepyMode.requireAuth"
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
        requireAuth = defaults.object(forKey: Keys.requireAuth) as? Bool ?? fallback.requireAuth
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
        config.requireAuth = requireAuth
        return config
    }

    private func persist(_ value: String, _ key: String) { defaults.set(value, forKey: key) }
    private func persist(_ value: Bool, _ key: String) { defaults.set(value, forKey: key) }
}
