import Foundation
import Observation
import OSLog
import CmuxSettings

/// Persisted, observable Sleepy Mode preferences. The renderer reads
/// `snapshot()` fresh each animation frame, so changing any value updates the
/// full-screen overlay immediately; the settings section binds to the same
/// store via `@Bindable`. Accessed only on the main thread in practice.
/// Owned by the app composition root (`SleepyModeController`) and injected into
/// the renderer and this section, rather than published as a package singleton.
///
/// This (and `SleepyModeConfig` / the theme enums) lives in CmuxSettingsUI by
/// design: Sleepy Mode appearance is user *settings*, and CmuxSettingsUI is
/// cmux's settings-model module — it already houses the other persisted settings
/// models the app consumes (`DefaultsValueModel`, `JSONValueModel`,
/// `SecretValueModel`, `MobilePairingStatusModel`, `SettingsErrorLog`). Splitting
/// one screensaver's settings into a separate domain package would fragment that
/// layer inconsistently.
@Observable
@MainActor
public final class SleepyModeSettingsStore {
    /// Mascot/scene color theme.
    public var theme: SleepyTheme { didSet { persist(theme.rawValue, SleepyModeDefaultsKeys.theme) } }
    /// Which mascot/face to draw.
    public var mascot: SleepyMascot { didSet { persist(mascot.rawValue, SleepyModeDefaultsKeys.mascot) } }
    /// Background glow gradient.
    public var glow: SleepyGlow { didSet { persist(glow.rawValue, SleepyModeDefaultsKeys.glow) } }
    /// Whether the moon is drawn.
    public var showMoon: Bool { didSet { persist(showMoon, SleepyModeDefaultsKeys.showMoon) } }
    /// Whether twinkling stars are drawn.
    public var showStars: Bool { didSet { persist(showStars, SleepyModeDefaultsKeys.showStars) } }
    /// Whether floating "z z z" are drawn.
    public var showZs: Bool { didSet { persist(showZs, SleepyModeDefaultsKeys.showZs) } }
    /// Whether the pixel clock and date are drawn.
    public var showClock: Bool { didSet { persist(showClock, SleepyModeDefaultsKeys.showClock) } }
    /// Whether the battery and Wi-Fi status are drawn.
    public var showStatus: Bool { didSet { persist(showStatus, SleepyModeDefaultsKeys.showStatus) } }
    /// Whether one walking pet per running agent is drawn.
    public var showPets: Bool { didSet { persist(showPets, SleepyModeDefaultsKeys.showPets) } }

    /// Custom face color ("RRGGBB"), used when `theme == .custom`.
    public var customFace: String { didSet { persist(customFace, SleepyModeDefaultsKeys.customFace) } }
    /// Custom nightcap color ("RRGGBB"), used when `theme == .custom`.
    public var customCap: String { didSet { persist(customCap, SleepyModeDefaultsKeys.customCap) } }
    /// Custom blush color ("RRGGBB"), used when `theme == .custom`.
    public var customBlush: String { didSet { persist(customBlush, SleepyModeDefaultsKeys.customBlush) } }
    /// Custom eye/ink color ("RRGGBB"), used when `theme == .custom`.
    public var customInk: String { didSet { persist(customInk, SleepyModeDefaultsKeys.customInk) } }
    /// Custom logo color ("RRGGBB"), used when `theme == .custom`.
    public var customLogo: String { didSet { persist(customLogo, SleepyModeDefaultsKeys.customLogo) } }
    /// Custom background color ("RRGGBB"), used when `glow == .custom`.
    public var customBackground: String { didSet { persist(customBackground, SleepyModeDefaultsKeys.customBackground) } }

    private let defaults: UserDefaults
    private let configStore: JSONConfigStore?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SleepyModeSettingsStore",
        category: "SleepyModeSettingsStore"
    )
    private var applyingDefaults = false
    private var defaultsObserver: NSObjectProtocol?

    /// Loads persisted preferences from `defaults` (inject an isolated
    /// `UserDefaults` for tests/previews); missing keys fall back to defaults.
    public init(defaults: UserDefaults = .standard, configStore: JSONConfigStore? = nil) {
        self.defaults = defaults
        self.configStore = configStore
        let fallback = SleepyModeConfig()
        theme = (defaults.string(forKey: SleepyModeDefaultsKeys.theme)).flatMap(SleepyTheme.init(rawValue:)) ?? fallback.theme
        mascot = (defaults.string(forKey: SleepyModeDefaultsKeys.mascot)).flatMap(SleepyMascot.init(rawValue:)) ?? fallback.mascot
        glow = (defaults.string(forKey: SleepyModeDefaultsKeys.glow)).flatMap(SleepyGlow.init(rawValue:)) ?? fallback.glow
        showMoon = defaults.object(forKey: SleepyModeDefaultsKeys.showMoon) as? Bool ?? fallback.showMoon
        showStars = defaults.object(forKey: SleepyModeDefaultsKeys.showStars) as? Bool ?? fallback.showStars
        showZs = defaults.object(forKey: SleepyModeDefaultsKeys.showZs) as? Bool ?? fallback.showZs
        showClock = defaults.object(forKey: SleepyModeDefaultsKeys.showClock) as? Bool ?? fallback.showClock
        showStatus = defaults.object(forKey: SleepyModeDefaultsKeys.showStatus) as? Bool ?? fallback.showStatus
        showPets = defaults.object(forKey: SleepyModeDefaultsKeys.showPets) as? Bool ?? fallback.showPets
        customFace = defaults.string(forKey: SleepyModeDefaultsKeys.customFace) ?? fallback.customFace
        customCap = defaults.string(forKey: SleepyModeDefaultsKeys.customCap) ?? fallback.customCap
        customBlush = defaults.string(forKey: SleepyModeDefaultsKeys.customBlush) ?? fallback.customBlush
        customInk = defaults.string(forKey: SleepyModeDefaultsKeys.customInk) ?? fallback.customInk
        customLogo = defaults.string(forKey: SleepyModeDefaultsKeys.customLogo) ?? fallback.customLogo
        customBackground = defaults.string(forKey: SleepyModeDefaultsKeys.customBackground) ?? fallback.customBackground
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromDefaults()
        }
    }

    deinit {
        // NotificationCenter retains the token and the closure captures self weakly.
        // Accessing the token from deinit is not actor-safe under Swift 6.
    }

    /// Re-reads the managed defaults snapshot after cmux.json is applied.
    /// The classic file store writes JSON values into these same keys, so this
    /// keeps the renderer and Settings pane live without a restart.
    private func reloadFromDefaults() {
        applyingDefaults = true
        defer { applyingDefaults = false }
        let fallback = SleepyModeConfig()
        let nextTheme = defaults.string(forKey: SleepyModeDefaultsKeys.theme).flatMap(SleepyTheme.init(rawValue:)) ?? fallback.theme
        let nextMascot = defaults.string(forKey: SleepyModeDefaultsKeys.mascot).flatMap(SleepyMascot.init(rawValue:)) ?? fallback.mascot
        let nextGlow = defaults.string(forKey: SleepyModeDefaultsKeys.glow).flatMap(SleepyGlow.init(rawValue:)) ?? fallback.glow
        if theme != nextTheme { theme = nextTheme }
        if mascot != nextMascot { mascot = nextMascot }
        if glow != nextGlow { glow = nextGlow }
        if showMoon != (defaults.object(forKey: SleepyModeDefaultsKeys.showMoon) as? Bool ?? fallback.showMoon) { showMoon = defaults.object(forKey: SleepyModeDefaultsKeys.showMoon) as? Bool ?? fallback.showMoon }
        if showStars != (defaults.object(forKey: SleepyModeDefaultsKeys.showStars) as? Bool ?? fallback.showStars) { showStars = defaults.object(forKey: SleepyModeDefaultsKeys.showStars) as? Bool ?? fallback.showStars }
        if showZs != (defaults.object(forKey: SleepyModeDefaultsKeys.showZs) as? Bool ?? fallback.showZs) { showZs = defaults.object(forKey: SleepyModeDefaultsKeys.showZs) as? Bool ?? fallback.showZs }
        if showClock != (defaults.object(forKey: SleepyModeDefaultsKeys.showClock) as? Bool ?? fallback.showClock) { showClock = defaults.object(forKey: SleepyModeDefaultsKeys.showClock) as? Bool ?? fallback.showClock }
        if showStatus != (defaults.object(forKey: SleepyModeDefaultsKeys.showStatus) as? Bool ?? fallback.showStatus) { showStatus = defaults.object(forKey: SleepyModeDefaultsKeys.showStatus) as? Bool ?? fallback.showStatus }
        if showPets != (defaults.object(forKey: SleepyModeDefaultsKeys.showPets) as? Bool ?? fallback.showPets) { showPets = defaults.object(forKey: SleepyModeDefaultsKeys.showPets) as? Bool ?? fallback.showPets }
        let strings: [(String, String)] = [
            (SleepyModeDefaultsKeys.customFace, customFace), (SleepyModeDefaultsKeys.customCap, customCap),
            (SleepyModeDefaultsKeys.customBlush, customBlush), (SleepyModeDefaultsKeys.customInk, customInk),
            (SleepyModeDefaultsKeys.customLogo, customLogo), (SleepyModeDefaultsKeys.customBackground, customBackground)
        ]
        let values = strings.map { defaults.string(forKey: $0.0) ?? $0.1 }
        if customFace != values[0] { customFace = values[0] }
        if customCap != values[1] { customCap = values[1] }
        if customBlush != values[2] { customBlush = values[2] }
        if customInk != values[3] { customInk = values[3] }
        if customLogo != values[4] { customLogo = values[4] }
        if customBackground != values[5] { customBackground = values[5] }
    }

    /// Returns an immutable snapshot of the current preferences for the renderer.
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

    private func persist(_ value: String, _ key: String) {
        defaults.set(value, forKey: key)
        guard !applyingDefaults, let configStore else { return }
        let jsonKey = JSONKey<String>(id: key, defaultValue: "")
        Task {
            do {
                try await configStore.set(value, for: jsonKey)
            } catch {
                logger.error("Failed to persist Sleepy Mode setting \(key, privacy: .public): \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func persist(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
        guard !applyingDefaults, let configStore else { return }
        let jsonKey = JSONKey<Bool>(id: key, defaultValue: false)
        Task {
            do {
                try await configStore.set(value, for: jsonKey)
            } catch {
                logger.error("Failed to persist Sleepy Mode setting \(key, privacy: .public): \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
