import CmuxSettings
import Foundation

extension CommandPaletteSettingsToggleCommands {
    /// The palette toggle for `automation.sessionPriority.enabled`, kept out of
    /// the length-budgeted descriptor table. Off by default.
    static func sessionPriorityDescriptor(
        sectionTitle: @escaping @Sendable () -> String
    ) -> CommandPaletteSettingToggleDescriptor {
        CommandPaletteSettingToggleDescriptor(
            commandId: commandIdPrefix + "sessionPriority",
            settingsKey: "automation.sessionPriority.enabled",
            title: {
                String(localized: "settings.automation.sessionPriority", defaultValue: "Prioritize Claude Sessions by Sidebar Order")
            },
            sectionTitle: sectionTitle,
            keywords: ["automation.sessionPriority", "session", "priority", "effort", "claude", "sidebar", "urgent"],
            defaultValue: AutomationCatalogSection().sessionPriority.defaultValue,
            defaultsKey: AutomationCatalogSection().sessionPriority.userDefaultsKey
        )
    }
}
