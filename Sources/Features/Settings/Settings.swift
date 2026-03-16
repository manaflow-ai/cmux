//
//  Settings.swift
//  cmux
//
//  Created by Gale Williams on 3/16/26.
//

import AppKit
import SwiftUI

private let cmuxAuxiliaryWindowIdentifiers: Set<String> = [
    "cmux.settings",
    "cmux.about",
    "cmux.licenses",
    "cmux.browser-popup",
    "cmux.settingsAboutTitlebarDebug",
    "cmux.debugWindowControls",
    "cmux.sidebarDebug",
    "cmux.menubarDebug",
    "cmux.backgroundDebug",
]

/// Returns whether the given window should handle the standard close shortcut
/// as a standalone auxiliary window instead of routing it through workspace or
/// panel-close behavior.
func cmuxWindowShouldOwnCloseShortcut(_ window: NSWindow?) -> Bool {
    guard let identifier = window?.identifier?.rawValue else { return false }
    return cmuxAuxiliaryWindowIdentifiers.contains(identifier)
}

// MARK: - SettingsAboutWindowKind

enum SettingsAboutWindowKind: String, CaseIterable, Identifiable {
    case settings
    case about

    // MARK: Computed Properties

    var id: String {
        rawValue
    }

    var displayTitle: String {
        switch self {
            case .settings:
                "Settings Window"
            case .about:
                "About Window"
        }
    }

    var windowIdentifier: String {
        switch self {
            case .settings:
                "cmux.settings"
            case .about:
                "cmux.about"
        }
    }

    var fallbackTitle: String {
        switch self {
            case .settings:
                "Settings"
            case .about:
                "About cmux"
        }
    }

    var minimumSize: NSSize {
        switch self {
            case .settings:
                NSSize(width: 420, height: 360)
            case .about:
                NSSize(width: 360, height: 520)
        }
    }
}

// MARK: - TitlebarVisibilityOption

enum TitlebarVisibilityOption: String, CaseIterable, Identifiable {
    case hidden
    case visible

    // MARK: Computed Properties

    var id: String {
        rawValue
    }

    var displayTitle: String {
        switch self {
            case .hidden:
                "Hidden"
            case .visible:
                "Visible"
        }
    }

    var windowValue: NSWindow.TitleVisibility {
        switch self {
            case .hidden:
                .hidden
            case .visible:
                .visible
        }
    }
}

// MARK: - TitlebarToolbarStyleOption

enum TitlebarToolbarStyleOption: String, CaseIterable, Identifiable {
    case automatic
    case expanded
    case preference
    case unified
    case unifiedCompact

    // MARK: Computed Properties

    var id: String {
        rawValue
    }

    var displayTitle: String {
        switch self {
            case .automatic:
                "Automatic"
            case .expanded:
                "Expanded"
            case .preference:
                "Preference"
            case .unified:
                "Unified"
            case .unifiedCompact:
                "Unified Compact"
        }
    }

    var windowValue: NSWindow.ToolbarStyle {
        switch self {
            case .automatic:
                .automatic
            case .expanded:
                .expanded
            case .preference:
                .preference
            case .unified:
                .unified
            case .unifiedCompact:
                .unifiedCompact
        }
    }
}

// MARK: - SettingsNavigationTarget

enum SettingsNavigationTarget: String {
    case keyboardShortcuts
}

// MARK: - SettingsNavigationRequest

enum SettingsNavigationRequest {
    // MARK: Static Properties

    static let notificationName = Notification.Name("cmux.settings.navigate")

    private static let targetKey = "target"

    // MARK: Static Functions

    static func post(_ target: SettingsNavigationTarget) {
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: [targetKey: target.rawValue]
        )
    }

    static func target(from notification: Notification) -> SettingsNavigationTarget? {
        guard let rawValue = notification.userInfo?[targetKey] as? String else { return nil }
        return SettingsNavigationTarget(rawValue: rawValue)
    }
}

// MARK: - AppearanceMode

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case auto

    // MARK: Static Computed Properties

    static var visibleCases: [AppearanceMode] {
        [.system, .light, .dark]
    }

    // MARK: Computed Properties

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
            case .system:
                String(localized: "appearance.system", defaultValue: "System")
            case .light:
                String(localized: "appearance.light", defaultValue: "Light")
            case .dark:
                String(localized: "appearance.dark", defaultValue: "Dark")
            case .auto:
                String(localized: "appearance.auto", defaultValue: "Auto")
        }
    }
}

// MARK: - AppearanceSettings

enum AppearanceSettings {
    // MARK: Static Properties

    static let appearanceModeKey = "appearanceMode"
    static let defaultMode: AppearanceMode = .system

    // MARK: Static Functions

    static func mode(for rawValue: String?) -> AppearanceMode {
        guard let rawValue, let mode = AppearanceMode(rawValue: rawValue) else {
            return defaultMode
        }
        if mode == .auto {
            return .system
        }
        return mode
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
}

// MARK: - AppLanguage

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case ar
    case bs
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case da
    case de
    case es
    case fr
    case it
    case ja
    case ko
    case nb
    case pl
    case ptBR = "pt-BR"
    case ru
    case th
    case tr

    // MARK: Computed Properties

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
            case .system: String(localized: "language.system", defaultValue: "System")
            case .en: "English"
            case .ar: "\u{200E}العربية (Arabic)"
            case .bs: "Bosanski (Bosnian)"
            case .zhHans: "简体中文 (Chinese Simplified)"
            case .zhHant: "繁體中文 (Chinese Traditional)"
            case .da: "Dansk (Danish)"
            case .de: "Deutsch (German)"
            case .es: "Español (Spanish)"
            case .fr: "Français (French)"
            case .it: "Italiano (Italian)"
            case .ja: "日本語 (Japanese)"
            case .ko: "한국어 (Korean)"
            case .nb: "Norsk (Norwegian)"
            case .pl: "Polski (Polish)"
            case .ptBR: "Português (Brasil)"
            case .ru: "Русский (Russian)"
            case .th: "ไทย (Thai)"
            case .tr: "Türkçe (Turkish)"
        }
    }
}

// MARK: - LanguageSettings

enum LanguageSettings {
    // MARK: Static Properties

    static let languageKey = "appLanguage"
    static let defaultLanguage: AppLanguage = .system

    static var languageAtLaunch: AppLanguage = {
        let stored = UserDefaults.standard.string(forKey: languageKey)
        guard let stored, let lang = AppLanguage(rawValue: stored) else { return .system }
        return lang
    }()

    // MARK: Static Functions

    static func apply(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}

// MARK: - AppIconMode

enum AppIconMode: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    // MARK: Computed Properties

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
            case .automatic: String(localized: "appIcon.automatic", defaultValue: "Automatic")
            case .light: String(localized: "appIcon.light", defaultValue: "Light")
            case .dark: String(localized: "appIcon.dark", defaultValue: "Dark")
        }
    }

    var imageName: String? {
        switch self {
            case .automatic: nil
            case .light: "AppIconLight"
            case .dark: "AppIconDark"
        }
    }
}

// MARK: - AppIconSettings

enum AppIconSettings {
    // MARK: Static Properties

    static let modeKey = "appIconMode"
    static let defaultMode: AppIconMode = .automatic

    // MARK: Static Functions

    static func resolvedMode(defaults: UserDefaults = .standard) -> AppIconMode {
        guard let raw = defaults.string(forKey: modeKey),
              let mode = AppIconMode(rawValue: raw)
        else {
            return defaultMode
        }
        return mode
    }

    static func applyIcon(_ mode: AppIconMode) {
        switch mode {
            case .automatic:
                // Let the asset catalog handle appearance-based icon selection (macOS 15+).
                // Reset to the default bundle icon.
                NSApplication.shared.applicationIconImage = nil

            case .light:
                if let icon = NSImage(named: "AppIconLight") {
                    NSApplication.shared.applicationIconImage = icon
                }

            case .dark:
                if let icon = NSImage(named: "AppIconDark") {
                    NSApplication.shared.applicationIconImage = icon
                }
        }
    }
}

// MARK: - QuitWarningSettings

enum QuitWarningSettings {
    // MARK: Static Properties

    static let warnBeforeQuitKey = "warnBeforeQuitShortcut"
    static let defaultWarnBeforeQuit = true

    // MARK: Static Functions

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: warnBeforeQuitKey) == nil {
            return defaultWarnBeforeQuit
        }
        return defaults.bool(forKey: warnBeforeQuitKey)
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: warnBeforeQuitKey)
    }
}

// MARK: - CommandPaletteRenameSelectionSettings

enum CommandPaletteRenameSelectionSettings {
    // MARK: Static Properties

    static let selectAllOnFocusKey = "commandPalette.renameSelectAllOnFocus"
    static let defaultSelectAllOnFocus = true

    // MARK: Static Functions

    static func selectAllOnFocusEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: selectAllOnFocusKey) == nil {
            return defaultSelectAllOnFocus
        }
        return defaults.bool(forKey: selectAllOnFocusKey)
    }
}

// MARK: - CommandPaletteSwitcherSearchSettings

enum CommandPaletteSwitcherSearchSettings {
    // MARK: Static Properties

    static let searchAllSurfacesKey = "commandPalette.switcherSearchAllSurfaces"
    static let defaultSearchAllSurfaces = false

    // MARK: Static Functions

    static func searchAllSurfacesEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: searchAllSurfacesKey) == nil {
            return defaultSearchAllSurfaces
        }
        return defaults.bool(forKey: searchAllSurfacesKey)
    }
}

// MARK: - ClaudeCodeIntegrationSettings

enum ClaudeCodeIntegrationSettings {
    // MARK: Static Properties

    static let hooksEnabledKey = "claudeCodeHooksEnabled"
    static let defaultHooksEnabled = true

    // MARK: Static Functions

    static func hooksEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hooksEnabledKey) == nil {
            return defaultHooksEnabled
        }
        return defaults.bool(forKey: hooksEnabledKey)
    }
}

// MARK: - WelcomeSettings

enum WelcomeSettings {
    static let shownKey = "cmuxWelcomeShown"
}

// MARK: - TelemetrySettings

enum TelemetrySettings {
    // MARK: Static Properties

    static let sendAnonymousTelemetryKey = "sendAnonymousTelemetry"
    static let defaultSendAnonymousTelemetry = true

    /// Freeze telemetry enablement once per launch. Settings changes apply on next restart.
    static let enabledForCurrentLaunch = isEnabled()

    // MARK: Static Functions

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: sendAnonymousTelemetryKey) == nil {
            return defaultSendAnonymousTelemetry
        }
        return defaults.bool(forKey: sendAnonymousTelemetryKey)
    }
}

// MARK: - SettingsTopOffsetPreferenceKey

struct SettingsTopOffsetPreferenceKey: PreferenceKey {
    // MARK: Static Properties

    static var defaultValue: CGFloat = 0

    // MARK: Static Functions

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
