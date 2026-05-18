import AppKit
import SwiftUI

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
    }

    struct SystemAppearance {
        let interfaceStyle: String?

        var prefersDark: Bool {
            interfaceStyle?.caseInsensitiveCompare(darkInterfaceStyleValue) == .orderedSame
        }

        static func current(defaults: UserDefaults = .standard) -> SystemAppearance {
            let directValue = defaults.string(forKey: appleInterfaceStyleKey)
            let globalValue = defaults
                .persistentDomain(forName: UserDefaults.globalDomain)?[appleInterfaceStyleKey] as? String
            return SystemAppearance(interfaceStyle: directValue ?? globalValue)
        }
    }

    static let appearanceModeKey = "appearanceMode"
    static let defaultMode: AppearanceMode = .system
    private static let appleInterfaceStyleKey = "AppleInterfaceStyle"
    private static let darkInterfaceStyleValue = "Dark"

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

    static func colorSchemePreference(
        appAppearance: NSAppearance? = nil,
        defaults: UserDefaults = .standard,
        systemAppearance: SystemAppearance? = nil
    ) -> GhosttyConfig.ColorSchemePreference {
        if let appAppearance {
            return appAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }

        let mode = mode(for: defaults.string(forKey: appearanceModeKey))
        if mode == .light { return .light }
        if mode == .dark { return .dark }
        return (systemAppearance ?? .current(defaults: defaults)).prefersDark ? .dark : .light
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
