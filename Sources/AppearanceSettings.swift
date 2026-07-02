import AppKit
import SwiftUI
import CmuxTerminalCore

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case auto

    var id: String { rawValue }

    static var visibleCases: [AppearanceMode] {
        [.system, .light, .dark]
    }

    var displayName: String {
        switch self {
        case .system:
            return String(localized: "appearance.system", defaultValue: "System")
        case .light:
            return String(localized: "appearance.light", defaultValue: "Light")
        case .dark:
            return String(localized: "appearance.dark", defaultValue: "Dark")
        case .auto:
            return String(localized: "appearance.auto", defaultValue: "Auto")
        }
    }
}

enum AppearanceSettings {
    struct LiveApplyEnvironment {
        let setApplicationAppearance: (NSAppearance?) -> Void
        let synchronizeTerminalThemeWithAppearance: (NSAppearance?, String) -> Void
        let systemAppearance: () -> NSAppearance?

        static var live: LiveApplyEnvironment {
            AppearanceSettings.currentLiveEnvironmentProvider()()
        }
    }

    private static let liveEnvironmentProviderLock = NSLock()
    private static var liveEnvironmentProvider: () -> LiveApplyEnvironment = {
        AppearanceSettings.defaultLiveEnvironment()
    }

    private static func currentLiveEnvironmentProvider() -> () -> LiveApplyEnvironment {
        liveEnvironmentProviderLock.lock()
        defer { liveEnvironmentProviderLock.unlock() }
        return liveEnvironmentProvider
    }

    private static func defaultLiveEnvironment() -> LiveApplyEnvironment {
        LiveApplyEnvironment(
            setApplicationAppearance: { appearance in
                NSApplication.shared.appearance = appearance
            },
            synchronizeTerminalThemeWithAppearance: { appearance, source in
                GhosttyApp.shared.synchronizeThemeWithAppearance(appearance, source: source)
            },
            systemAppearance: {
                AppearanceSettings.systemNSAppearance()
            }
        )
    }

    /// The system interface-style snapshot used by terminal color-scheme
    /// resolution. Lifted to ``TerminalSystemAppearance`` in CmuxTerminalCore so
    /// the terminal config type no longer reaches up into the app's appearance
    /// settings; this alias keeps the `AppearanceSettings.SystemAppearance`
    /// call-site name byte-identical.
    typealias SystemAppearance = TerminalSystemAppearance

    static let appearanceModeKey = "appearanceMode"
    static let defaultMode: AppearanceMode = .system

    static func mode(for rawValue: String?) -> AppearanceMode {
        guard let rawValue, let mode = AppearanceMode(rawValue: rawValue) else {
            return defaultMode
        }
        return mode == .auto ? .system : mode
    }

    @discardableResult
    static func resolvedMode(defaults: UserDefaults = .standard) -> AppearanceMode {
        let stored = defaults.string(forKey: appearanceModeKey)
        let resolved = mode(for: stored)
        if stored != resolved.rawValue {
            defaults.set(resolved.rawValue, forKey: appearanceModeKey)
        }
        return resolved
    }

    /// Returns the Ghostty terminal color-scheme preference.
    /// - Note: `colorSchemePreference` keeps the `appAppearance` parameter for API compatibility
    ///   and intentionally ignores it.
    static func colorSchemePreference(
        appAppearance _: NSAppearance? = nil,
        defaults: UserDefaults = .standard,
        systemAppearance: SystemAppearance? = nil
    ) -> GhosttyConfig.ColorSchemePreference {
        terminalColorSchemePreference(defaults: defaults, systemAppearance: systemAppearance)
    }

    // Ghostty split-theme resolution follows cmux's persisted appearance mode.
    // AppKit view/window appearances can lag during live mode changes.
    // The resolution itself now lives in CmuxTerminalCore
    // (TerminalColorSchemePreference.resolve); this forwards the app's
    // normalized appearance mode into it so both surfaces share one source of
    // truth.
    static func terminalColorSchemePreference(
        defaults: UserDefaults = .standard,
        systemAppearance: SystemAppearance? = nil
    ) -> GhosttyConfig.ColorSchemePreference {
        TerminalColorSchemePreference.resolve(
            appearanceModeRawValue: mode(for: defaults.string(forKey: appearanceModeKey)).rawValue,
            systemAppearance: systemAppearance,
            defaults: defaults
        )
    }

    static func systemNSAppearance(defaults: UserDefaults = .standard) -> NSAppearance? {
        NSAppearance(named: SystemAppearance.current(defaults: defaults).prefersDark ? .darkAqua : .aqua)
    }

    static func colorSchemeOverride(for rawValue: String?) -> ColorScheme? {
        switch mode(for: rawValue) {
        case .system, .auto:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    static func colorScheme(for rawValue: String?, fallback: ColorScheme) -> ColorScheme {
        colorSchemeOverride(for: rawValue) ?? fallback
    }

    @discardableResult
    static func selectMode(
        _ mode: AppearanceMode,
        defaults: UserDefaults = .standard,
        source: String,
        environment: LiveApplyEnvironment = .live
    ) -> AppearanceMode {
        let normalized = Self.mode(for: mode.rawValue)
        defaults.set(normalized.rawValue, forKey: appearanceModeKey)
        applyLiveMode(normalized, source: source, environment: environment)
        return normalized
    }

    @discardableResult
    static func applyStoredMode(
        rawValue: String?,
        defaults: UserDefaults = .standard,
        source: String,
        duringLaunch: Bool = false,
        synchronizeTerminalTheme: Bool = true,
        environment: LiveApplyEnvironment = .live
    ) -> AppearanceMode {
        let normalized = Self.mode(for: rawValue)
        if rawValue != normalized.rawValue {
            defaults.set(normalized.rawValue, forKey: appearanceModeKey)
        }
        applyLiveMode(
            normalized,
            source: source,
            duringLaunch: duringLaunch,
            synchronizeTerminalTheme: synchronizeTerminalTheme,
            environment: environment
        )
        return normalized
    }

    @discardableResult
    static func applyLiveMode(
        _ mode: AppearanceMode,
        source: String,
        duringLaunch: Bool = false,
        synchronizeTerminalTheme: Bool = true,
        environment: LiveApplyEnvironment = .live
    ) -> AppearanceMode {
        let normalized = Self.mode(for: mode.rawValue)
        let appearance = applicationAppearance(
            for: normalized,
            duringLaunch: duringLaunch,
            environment: environment
        )
        environment.setApplicationAppearance(appearance)
        if synchronizeTerminalTheme {
            environment.synchronizeTerminalThemeWithAppearance(appearance, source)
        }
        return normalized
    }

    private static func applicationAppearance(
        for mode: AppearanceMode,
        duringLaunch: Bool,
        environment: LiveApplyEnvironment
    ) -> NSAppearance? {
        switch mode {
        case .system:
            return duringLaunch ? environment.systemAppearance() : nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        case .auto:
            return nil
        }
    }

    static func setLiveEnvironmentProviderForTesting(_ provider: @escaping () -> LiveApplyEnvironment) {
        liveEnvironmentProviderLock.lock()
        defer { liveEnvironmentProviderLock.unlock() }
        liveEnvironmentProvider = provider
    }

    static func resetLiveEnvironmentProviderForTesting() {
        liveEnvironmentProviderLock.lock()
        defer { liveEnvironmentProviderLock.unlock() }
        liveEnvironmentProvider = {
            AppearanceSettings.defaultLiveEnvironment()
        }
    }
}

final class AppearanceSettingsUserDefaultsObserver {
    struct Environment {
        let addDefaultsObserver: (@escaping () -> Void) -> NSObjectProtocol
        let removeObserver: (NSObjectProtocol) -> Void
        let currentRawValue: () -> String?
        let applyStoredMode: (String?, String) -> AppearanceMode

        static func live(
            defaults: UserDefaults = .standard,
            notificationCenter: NotificationCenter = .default
        ) -> Environment {
            Environment(
                addDefaultsObserver: { handler in
                    notificationCenter.addObserver(
                        forName: UserDefaults.didChangeNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        handler()
                    }
                },
                removeObserver: { observer in
                    notificationCenter.removeObserver(observer)
                },
                currentRawValue: {
                    defaults.string(forKey: AppearanceSettings.appearanceModeKey)
                },
                applyStoredMode: { rawValue, source in
                    AppearanceSettings.applyStoredMode(
                        rawValue: rawValue,
                        defaults: defaults,
                        source: source
                    )
                }
            )
        }
    }

    static let shared = AppearanceSettingsUserDefaultsObserver()

    private let environment: Environment
    private var defaultsObserver: NSObjectProtocol?
    private var lastObservedRawValue: String?
    private var source: String

    init(
        environment: Environment = .live(),
        source: String = "cmuxApp.appearanceDefaultsChanged"
    ) {
        self.environment = environment
        self.source = source
    }

    deinit {
        stopObserving()
    }

    func startObserving(source: String? = nil) {
        if let source {
            self.source = source
        }
        lastObservedRawValue = environment.currentRawValue()
        guard defaultsObserver == nil else { return }
        defaultsObserver = environment.addDefaultsObserver { [weak self] in
            self?.applyIfChanged()
        }
    }

    func stopObserving() {
        guard let defaultsObserver else { return }
        environment.removeObserver(defaultsObserver)
        self.defaultsObserver = nil
    }

    private func applyIfChanged() {
        let rawValue = environment.currentRawValue()
        guard rawValue != lastObservedRawValue else { return }
        let appliedMode = environment.applyStoredMode(rawValue, source)
        lastObservedRawValue = appliedMode.rawValue
    }
}

extension Notification.Name {
    /// Posted on the main thread whenever the system's effective appearance
    /// changes (e.g. a macOS scheduled "Auto" Light↔Dark switch). Distinct from
    /// the cmux appearance *setting* change tracked by
    /// `AppearanceSettingsUserDefaultsObserver`: this fires when the OS — not the
    /// user's cmux preference — flips appearance. See #6385.
    static let systemAppearanceDidChange = Notification.Name("systemAppearanceDidChange")
}

/// Bridges OS-driven appearance switches into the app's chrome-refresh path.
///
/// When macOS flips appearance on a schedule (System Settings → Appearance →
/// Auto), `NSApp.effectiveAppearance` updates and the terminal re-themes itself,
/// but cmux's own chrome (sidebar text, titlebar) caches a color-scheme snapshot
/// that is only invalidated by unrelated events — so it stays stale until a tab
/// switch forces a re-render (#6385). This observer watches
/// `NSApp.effectiveAppearance` and posts `.systemAppearanceDidChange`, which
/// `ContentView` turns into a `scheduleTitlebarThemeRefresh(...)` — the same
/// invalidation a tab switch triggers, just automatically.
///
/// It is intentionally separate from `AppIconAppearanceObserver`, which observes
/// the same key path but is torn down whenever the app icon isn't in automatic
/// mode, so it cannot be relied upon to refresh app chrome.
final class SystemAppearanceObserver {
    struct Environment {
        let startEffectiveAppearanceObservation: (@escaping () -> Void) -> EffectiveAppearanceObservation?
        let postNotification: () -> Void

        static func live(notificationCenter: NotificationCenter = .default) -> Environment {
            Environment(
                startEffectiveAppearanceObservation: { handler in
                    guard let app = NSApp else { return nil }
                    return app.observe(\.effectiveAppearance, options: []) { _, _ in
                        DispatchQueue.main.async {
                            handler()
                        }
                    }
                },
                postNotification: {
                    notificationCenter.post(name: .systemAppearanceDidChange, object: nil)
                }
            )
        }
    }

    static let shared = SystemAppearanceObserver()

    private let environment: Environment
    private var observation: EffectiveAppearanceObservation?

    init(environment: Environment = .live()) {
        self.environment = environment
    }

    deinit {
        stopObserving()
    }

    /// Begin observing `NSApp.effectiveAppearance`. Start this once launch has
    /// completed (past the macOS Tahoe `App.init()` crash window for touching
    /// `effectiveAppearance`). Idempotent.
    func startObserving() {
        guard observation == nil else { return }
        observation = environment.startEffectiveAppearanceObservation { [weak self] in
            guard let self, self.observation != nil else { return }
            self.environment.postNotification()
        }
    }

    func stopObserving() {
        observation?.invalidate()
        observation = nil
    }
}

private struct AppearanceColorSchemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let rawValue: String?

    func body(content: Content) -> some View {
        let override = AppearanceSettings.colorSchemeOverride(for: rawValue)
        let effective = AppearanceSettings.colorScheme(for: rawValue, fallback: colorScheme)
        content
            .environment(\.colorScheme, effective)
            .preferredColorScheme(override)
    }
}

extension View {
    func cmuxAppearanceColorScheme(_ rawValue: String?) -> some View {
        modifier(AppearanceColorSchemeModifier(rawValue: rawValue))
    }
}
