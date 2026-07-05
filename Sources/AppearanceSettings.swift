import AppKit
import SwiftUI
import CmuxTerminalCore

extension Notification.Name {
    /// Posted by SystemAppearanceObserver when NSApp.effectiveAppearance changes (#6385).
    static let systemAppearanceDidChange = Notification.Name("cmux.systemAppearanceDidChange")
}

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
        return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
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

/// Shared observation contract used by `AppIconAppearanceObserver` (cmuxApp.swift)
/// and `SystemAppearanceObserver`.
protocol EffectiveAppearanceObservation: AnyObject {
    func invalidate()
}

extension NSKeyValueObservation: EffectiveAppearanceObservation {}

/// Keeps the app chrome in sync with live macOS appearance changes while the
/// appearance mode is `system`.
///
/// With `NSApplication.appearance == nil`, AppKit updates `effectiveAppearance`
/// when the OS switches Light/Dark, but the SwiftUI hosting layer does not
/// reliably re-resolve the ambient `colorScheme` for already-visible windows
/// (visible when the switch is triggered by Shortcuts' "Set Appearance" or the
/// scheduled Auto switch, #6385). This observer is detect-and-notify only: it
/// KVO-watches `NSApp.effectiveAppearance` and, in system mode, diffs the
/// freshly resolved value against the last-resolved one, and — only on an
/// actual change — posts `.systemAppearanceDidChange` so interested views
/// (see `AppearanceColorSchemeModifier`) can re-resolve their color scheme
/// directly from `NSApp.effectiveAppearance` and force a body recomputation.
///
/// It is intentionally separate from `AppIconAppearanceObserver`, which observes
/// the same key path but is torn down whenever the app icon isn't in automatic
/// mode, so it cannot be relied upon to refresh app chrome. The two observers
/// own different lifecycles on purpose: the icon observer's teardown is keyed
/// to icon mode, while chrome refresh must stay armed for the whole app
/// lifetime — a single shared observer would couple those lifecycles.
///
/// The AppleInterfaceStyle default is NOT a reliable fresh source here: on
/// scripted appearance changes (Shortcuts "Set Appearance"), this process's
/// CFPreferences view of the global domain can remain stale long after AppKit
/// has resolved the new effectiveAppearance — runtime traces show both the
/// direct and globalDomain reads returning the pre-toggle value.
/// effectiveAppearance is the ground truth for this observer.
@MainActor
final class SystemAppearanceObserver {
    struct Environment {
        let startEffectiveAppearanceObservation: (@escaping () -> Void) -> EffectiveAppearanceObservation?
        let currentAppearanceModeRawValue: () -> String?
        let effectivePrefersDark: () -> Bool
        let postSystemAppearanceDidChange: () -> Void

        static func live() -> Environment {
            Environment(
                startEffectiveAppearanceObservation: { handler in
                    // `Environment` is nested in the now-`@MainActor` `SystemAppearanceObserver`,
                    // which makes the compiler check this closure's body for actor-isolation
                    // crossings even though `startEffectiveAppearanceObservation`'s declared type
                    // stays plain/non-isolated. `startObserving()` (the only caller) is
                    // main-actor-isolated, so this always runs on the main actor in practice;
                    // `assumeIsolated` makes that explicit for the type checker.
                    MainActor.assumeIsolated {
                        guard let app = NSApp else { return nil }
                        return app.observe(\.effectiveAppearance, options: []) { _, _ in
                            DispatchQueue.main.async { handler() }
                        }
                    }
                },
                currentAppearanceModeRawValue: {
                    UserDefaults.standard.string(forKey: AppearanceSettings.appearanceModeKey)
                },
                effectivePrefersDark: {
                    MainActor.assumeIsolated {
                        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    }
                },
                postSystemAppearanceDidChange: {
                    NotificationCenter.default.post(name: .systemAppearanceDidChange, object: nil)
                }
            )
        }
    }

    static let shared = SystemAppearanceObserver()

    private let environment: Environment
    private var observation: EffectiveAppearanceObservation?
    private var lastResolvedPrefersDark: Bool?

    init(environment: Environment = .live()) {
        self.environment = environment
    }

    func startObserving() {
        guard observation == nil else { return }
        lastResolvedPrefersDark = environment.effectivePrefersDark()
        observation = environment.startEffectiveAppearanceObservation { [weak self] in
            // `startEffectiveAppearanceObservation`'s handler parameter is plain/non-isolated
            // (see `Environment.live()`), but it is only ever invoked via
            // `DispatchQueue.main.async` there, so this always runs on the main actor.
            MainActor.assumeIsolated {
                self?.handleEffectiveAppearanceChange()
            }
        }
    }

    // No deinit: `shared` never deallocates, and `NSKeyValueObservation` (the
    // concrete `EffectiveAppearanceObservation` returned by
    // `startEffectiveAppearanceObservation`) self-invalidates at dealloc anyway.
    func stopObserving() {
        observation?.invalidate()
        observation = nil
    }

    private func handleEffectiveAppearanceChange() {
        // Stale-fire guard: the KVO handler can still be in flight (or
        // re-entrantly triggered, see below) after `stopObserving()` has run.
        guard observation != nil else { return }
        guard AppearanceSettings.mode(for: environment.currentAppearanceModeRawValue()) == .system else { return }
        let prefersDark = environment.effectivePrefersDark()
        guard prefersDark != lastResolvedPrefersDark else { return }
        lastResolvedPrefersDark = prefersDark
        cmuxDebugLog("systemAppearance.observer.change prefersDark=\(prefersDark)")
        environment.postSystemAppearanceDidChange()
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
