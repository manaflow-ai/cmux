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

    /// Resolves the color scheme the chrome should render with. Explicit modes
    /// win; system mode resolves from the app's live effectiveAppearance, which
    /// (unlike the AppleInterfaceStyle default) stays fresh on scripted
    /// appearance changes.
    @MainActor
    static func effectiveColorScheme(for rawValue: String?, fallback: ColorScheme) -> ColorScheme {
        if let override = colorSchemeOverride(for: rawValue) { return override }
        guard let app = NSApp else { return fallback }
        return app.effectiveAppearance.cmuxPrefersDark ? .dark : .light
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

/// Re-resolves and re-injects the color scheme at the window root.
///
/// In system mode, the ambient `colorScheme` supplied by the hosting bridge's
/// `@Environment` can go stale on scripted OS appearance changes (Shortcuts'
/// "Set Appearance", #6385) — SwiftUI doesn't reliably re-resolve it for
/// already-visible windows. So in system mode this modifier ignores the
/// ambient value and instead resolves fresh from `NSApp.effectiveAppearance`
/// (see `AppearanceSettings.effectiveColorScheme`), then re-injects the result
/// at the window root via `.environment(\.colorScheme, ...)` so it propagates
/// to every descendant that reads the ambient color scheme. Re-resolution is
/// keyed off `.systemAppearanceDidChange`, which `SystemAppearanceObserver`
/// posts whenever the effective appearance actually changes while in system
/// mode.
private struct AppearanceColorSchemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @State private var systemAppearanceGeneration = 0
    let rawValue: String?

    func body(content: Content) -> some View {
        let override = AppearanceSettings.colorSchemeOverride(for: rawValue)
        let _ = systemAppearanceGeneration
        let effective = AppearanceSettings.effectiveColorScheme(for: rawValue, fallback: colorScheme)
        content
            .environment(\.colorScheme, effective)
            .preferredColorScheme(override)
            .onReceive(NotificationCenter.default.publisher(for: .systemAppearanceDidChange)) { _ in
                systemAppearanceGeneration &+= 1
            }
    }
}

extension View {
    func cmuxAppearanceColorScheme(_ rawValue: String?) -> some View {
        modifier(AppearanceColorSchemeModifier(rawValue: rawValue))
    }
}
