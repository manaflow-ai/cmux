import Foundation

nonisolated extension CatalogArgument {
    /// Optional Settings window section (`openSettings`); the values are the
    /// Settings module's `SettingsSection` raw values (a test checks it).
    static var settingsSectionChoice: ActionArgument {
        ActionArgument(
            name: "section", title: String(localized: "argument.section", defaultValue: "Section", table: "SettingsActions", bundle: .module),
            kind: .enumeration([
                ActionEnumCase(value: "general", title: text("argument.value.section.general", "General")),
                ActionEnumCase(value: "appearance", title: text("argument.value.section.appearance", "Appearance")),
                ActionEnumCase(value: "terminal", title: text("argument.value.section.terminal", "Terminal")),
                ActionEnumCase(value: "browser", title: text("argument.value.section.browser", "Browser")),
                ActionEnumCase(value: "keyboard", title: text("argument.value.section.keyboard", "Keyboard")),
                ActionEnumCase(value: "notifications", title: text("argument.value.section.notifications", "Notifications")),
                ActionEnumCase(value: "accounts", title: text("argument.value.section.accounts", "Accounts")),
                ActionEnumCase(value: "rooms", title: text("argument.value.section.rooms", "Spaces & Profiles")),
                ActionEnumCase(value: "machines", title: text("argument.value.section.machines", "Machines")),
                ActionEnumCase(value: "advanced", title: text("argument.value.section.advanced", "Advanced")),
            ]),
            isRequired: false)
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "SettingsActions", bundle: .module)
    }
}
