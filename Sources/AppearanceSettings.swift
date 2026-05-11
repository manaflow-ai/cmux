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
        let persistManagedTerminalAppearanceConfig: (AppearanceMode, NSAppearance?, UserDefaults, String) -> Task<Void, Never>?

        init(
            setApplicationAppearance: @escaping (NSAppearance?) -> Void,
            synchronizeTerminalThemeWithAppearance: @escaping (NSAppearance?, String) -> Void,
            systemAppearance: @escaping () -> NSAppearance?,
            persistManagedTerminalAppearanceConfig: @escaping (AppearanceMode, NSAppearance?, UserDefaults, String) -> Task<Void, Never>? = { _, _, _, _ in nil }
        ) {
            self.setApplicationAppearance = setApplicationAppearance
            self.synchronizeTerminalThemeWithAppearance = synchronizeTerminalThemeWithAppearance
            self.systemAppearance = systemAppearance
            self.persistManagedTerminalAppearanceConfig = persistManagedTerminalAppearanceConfig
        }

        static var live: LiveApplyEnvironment {
            LiveApplyEnvironment(
                setApplicationAppearance: { appearance in
                    NSApplication.shared.appearance = appearance
                },
                synchronizeTerminalThemeWithAppearance: { appearance, source in
                    GhosttyApp.shared.synchronizeThemeWithAppearance(
                        appearance,
                        source: source,
                        persistManagedTerminalAppearanceConfig: { _, _, _, _ in nil }
                    )
                },
                systemAppearance: {
                    AppearanceSettings.systemNSAppearance()
                },
                persistManagedTerminalAppearanceConfig: AppearanceSettings.liveManagedTerminalAppearanceConfigPersistence
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
    private static let managedTerminalAppearanceWriteQueue = DispatchQueue(
        label: "com.cmux.appearance.managedTerminalConfig"
    )

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
        applyLiveMode(normalized, source: source, defaults: defaults, environment: environment)
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
            defaults: defaults,
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
        defaults: UserDefaults = .standard,
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
        let persistenceTask = environment.persistManagedTerminalAppearanceConfig(
            normalized,
            appearance,
            defaults,
            source
        )
        if synchronizeTerminalTheme {
            synchronizeTerminalThemeWithAppearance(
                appearance,
                source: source,
                persistenceTask: persistenceTask,
                environment: environment
            )
        }
        return normalized
    }

#if compiler(>=6.2)
    @concurrent
#endif
    nonisolated
    static func persistManagedTerminalAppearanceConfig(
        _ mode: AppearanceMode,
        appAppearance: NSAppearance?,
        defaults: UserDefaults = .standard,
        source: String,
        environment: ConfigSourceEnvironment = .live()
    ) {
        let normalized = Self.mode(for: mode.rawValue)
        let colorScheme = managedTerminalColorScheme(
            for: normalized,
            appAppearance: appAppearance,
            defaults: defaults
        )
        let managedBlock = managedTerminalAppearanceBlock(
            mode: normalized,
            colorScheme: colorScheme
        )

        persistManagedTerminalAppearanceBlock(
            managedBlock,
            source: source,
            environment: environment
        )
    }

#if compiler(>=6.2)
    @concurrent
#endif
    nonisolated
    static func persistManagedTerminalAppearanceBlock(
        _ managedBlock: String,
        source: String,
        environment: ConfigSourceEnvironment = .live()
    ) {
        do {
            let url = environment.cmuxConfigURL
            let existingContents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updatedContents = replacingManagedTerminalAppearanceBlock(
                in: existingContents,
                with: managedBlock
            )
            guard updatedContents != existingContents else { return }
            try environment.writeCmuxConfigContents(updatedContents)
        } catch {
            #if DEBUG
            cmuxDebugLog("appearance.ghosttyConfig.persist.failed source=\(source) error=\(error)")
            #endif
        }
    }

    static var liveManagedTerminalAppearanceConfigPersistence: (AppearanceMode, NSAppearance?, UserDefaults, String) -> Task<Void, Never>? {
        { mode, appearance, defaults, source in
            let normalized = Self.mode(for: mode.rawValue)
            let colorScheme = managedTerminalColorScheme(
                for: normalized,
                appAppearance: appearance,
                defaults: defaults
            )
            let managedBlock = managedTerminalAppearanceBlock(
                mode: normalized,
                colorScheme: colorScheme
            )

            let completion = AsyncStream<Void> { continuation in
                managedTerminalAppearanceWriteQueue.async {
                    persistManagedTerminalAppearanceBlock(
                        managedBlock,
                        source: source
                    )
                    continuation.yield(())
                    continuation.finish()
                }
            }

            return Task(priority: .utility) {
                for await _ in completion {}
            }
        }
    }

    private static func synchronizeTerminalThemeWithAppearance(
        _ appearance: NSAppearance?,
        source: String,
        persistenceTask: Task<Void, Never>?,
        environment: LiveApplyEnvironment
    ) {
        guard let persistenceTask else {
            environment.synchronizeTerminalThemeWithAppearance(appearance, source)
            return
        }

        Task { @MainActor in
            await persistenceTask.value
            environment.synchronizeTerminalThemeWithAppearance(appearance, source)
        }
    }

    private static func managedTerminalColorScheme(
        for mode: AppearanceMode,
        appAppearance: NSAppearance?,
        defaults: UserDefaults
    ) -> GhosttyConfig.ColorSchemePreference {
        switch mode {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system, .auto:
            return GhosttyConfig.currentColorSchemePreference(
                appAppearance: appAppearance ?? systemNSAppearance(defaults: defaults),
                defaults: defaults
            )
        }
    }

    private static let managedTerminalAppearanceBeginMarker = "# cmux-managed-appearance: begin"
    private static let managedTerminalAppearanceEndMarker = "# cmux-managed-appearance: end"

    private static func managedTerminalAppearanceBlock(
        mode: AppearanceMode,
        colorScheme: GhosttyConfig.ColorSchemePreference
    ) -> String {
        let body = GhosttyConfig.cmuxDefaultThemeConfigContents(
            preferredColorScheme: colorScheme
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        \(managedTerminalAppearanceBeginMarker)
        # Generated by cmux from the app appearance setting.
        # mode = \(mode.rawValue)
        \(body)
        \(managedTerminalAppearanceEndMarker)

        """
    }

    private static func replacingManagedTerminalAppearanceBlock(
        in contents: String,
        with managedBlock: String
    ) -> String {
        if contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return managedBlock
        }

        if let startRange = contents.range(of: managedTerminalAppearanceBeginMarker) {
            let replacementStart = contents[..<startRange.lowerBound]
                .lastIndex(of: "\n")
                .map { contents.index(after: $0) } ?? contents.startIndex
            guard let endRange = contents.range(
                of: managedTerminalAppearanceEndMarker,
                range: startRange.upperBound..<contents.endIndex
            ) else {
                var updated = contents
                updated.replaceSubrange(replacementStart..<contents.endIndex, with: managedBlock)
                return updated.hasSuffix("\n") ? updated : updated + "\n"
            }

            let replacementEnd = contents[endRange.upperBound...]
                .firstIndex(of: "\n")
                .map { contents.index(after: $0) } ?? contents.endIndex
            var updated = contents
            updated.replaceSubrange(replacementStart..<replacementEnd, with: managedBlock)
            return updated.hasSuffix("\n") ? updated : updated + "\n"
        }

        let separator = contents.hasSuffix("\n") ? "\n" : "\n\n"
        return contents + separator + managedBlock
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
