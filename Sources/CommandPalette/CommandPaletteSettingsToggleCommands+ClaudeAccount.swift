import CmuxSettings
import Foundation

extension CommandPaletteSettingsToggleCommands {
    /// The palette toggle for `automation.claudeAccountAutoSwitch`, kept out of
    /// the length-budgeted descriptor table. Off by default.
    static func claudeAccountAutoSwitchDescriptor(
        sectionTitle: @escaping @Sendable () -> String
    ) -> CommandPaletteSettingToggleDescriptor {
        CommandPaletteSettingToggleDescriptor(
            commandId: commandIdPrefix + "claudeAccountAutoSwitch",
            settingsKey: "automation.claudeAccountAutoSwitch",
            title: {
                String(localized: "settings.automation.claudeAccountAutoSwitch", defaultValue: "Switch Claude Account on Usage Limit")
            },
            sectionTitle: sectionTitle,
            keywords: ["automation.claudeAccountAutoSwitch", "claude", "account", "switch", "usage", "limit", "quota"],
            defaultValue: AutomationCatalogSection().claudeAccountAutoSwitch.defaultValue,
            defaultsKey: AutomationCatalogSection().claudeAccountAutoSwitch.userDefaultsKey
        )
    }
}
