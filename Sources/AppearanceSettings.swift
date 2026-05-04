import AppKit

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
}
