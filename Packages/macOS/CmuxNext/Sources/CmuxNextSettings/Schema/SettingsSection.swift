import CmuxNextDesign
import Foundation

/// The Settings window's sections, in sidebar order. The raw value is the
/// `section` argument of Settings… (`cmux settings open --section keyboard`).
public nonisolated enum SettingsSection: String, Sendable, Hashable, CaseIterable, Identifiable {
    case general, appearance, terminal, browser, home, keyboard, notifications, accounts, rooms, machines, advanced

    public var id: String { rawValue }

    /// The string catalog key of `title`.
    public var titleKey: String { "settings.section.\(rawValue)" }

    public var title: String {
        switch self {
        case .general: SettingsText.text("settings.section.general", "General")
        case .appearance: SettingsText.text("settings.section.appearance", "Appearance")
        case .terminal: SettingsText.text("settings.section.terminal", "Terminal")
        case .browser: SettingsText.text("settings.section.browser", "Browser")
        case .home: SettingsText.text("settings.section.home", "Home")
        case .keyboard: SettingsText.text("settings.section.keyboard", "Keyboard")
        case .notifications: SettingsText.text("settings.section.notifications", "Notifications")
        case .accounts: SettingsText.text("settings.section.accounts", "Accounts")
        case .rooms: SettingsText.text("settings.section.rooms", "Spaces & Profiles")
        case .machines: SettingsText.text("settings.section.machines", "Machines")
        case .advanced: SettingsText.text("settings.section.advanced", "Advanced")
        }
    }

    /// SF Symbol for the sidebar row.
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .terminal: "terminal"
        case .browser: "globe"
        case .home: "house"
        case .keyboard: "keyboard"
        case .notifications: "bell"
        case .accounts: "person.crop.circle"
        case .rooms: "square.stack"
        case .machines: "server.rack"
        case .advanced: "curlybraces"
        }
    }
}

/// Localized text of the settings schema (Localizable.xcstrings in this module).
nonisolated enum SettingsText {
    /// `text` with its key, for schema texts that clients outside the app
    /// localize (`SettingsSchemaExport`).
    static func keyed(
        _ key: StaticString,
        _ value: String.LocalizationValue,
        strings: ModuleResourceBundle = .settings
    ) -> SettingText {
        SettingText(key: "\(key)", text: strings.text(key, defaultValue: value))
    }

    static func text(
        _ key: StaticString,
        _ value: String.LocalizationValue,
        strings: ModuleResourceBundle = .settings
    ) -> String {
        strings.text(key, defaultValue: value)
    }
}
