import Foundation
import Observation

/// Persisted, observable Sleepy Mode preferences. The renderer reads
/// `snapshot()` fresh each animation frame, so changing any value updates both
/// the full-screen overlay and the settings live preview immediately.
@Observable
final class SleepyModeSettingsStore {
    static let shared = SleepyModeSettingsStore()

    var theme: SleepyTheme { didSet { persist(theme.rawValue, Keys.theme) } }
    var mascot: SleepyMascot { didSet { persist(mascot.rawValue, Keys.mascot) } }
    var glow: SleepyGlow { didSet { persist(glow.rawValue, Keys.glow) } }
    var showMoon: Bool { didSet { persist(showMoon, Keys.showMoon) } }
    var showStars: Bool { didSet { persist(showStars, Keys.showStars) } }
    var showZs: Bool { didSet { persist(showZs, Keys.showZs) } }
    var showClock: Bool { didSet { persist(showClock, Keys.showClock) } }
    var showStatus: Bool { didSet { persist(showStatus, Keys.showStatus) } }
    var requireAuth: Bool { didSet { persist(requireAuth, Keys.requireAuth) } }

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
        static let requireAuth = "sleepyMode.requireAuth"
    }

    init(defaults: UserDefaults = .standard) {
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
        requireAuth = defaults.object(forKey: Keys.requireAuth) as? Bool ?? fallback.requireAuth
    }

    func snapshot() -> SleepyModeConfig {
        SleepyModeConfig(
            theme: theme,
            mascot: mascot,
            glow: glow,
            showMoon: showMoon,
            showStars: showStars,
            showZs: showZs,
            showClock: showClock,
            showStatus: showStatus,
            requireAuth: requireAuth
        )
    }

    private func persist(_ value: String, _ key: String) { defaults.set(value, forKey: key) }
    private func persist(_ value: Bool, _ key: String) { defaults.set(value, forKey: key) }
}
