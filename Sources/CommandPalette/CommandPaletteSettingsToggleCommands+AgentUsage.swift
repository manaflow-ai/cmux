import CmuxSettings
import Foundation

extension CommandPaletteSettingsToggleCommands {
    /// The palette toggle for `sidebar.showAgentUsage`, kept out of the
    /// length-budgeted descriptor table. Usage renders inside the custom
    /// metadata rows, so the toggle is hidden while "Hide All Details" is on
    /// (`isAvailable`) or custom metadata is off.
    static func sidebarAgentUsageDescriptor(
        sectionTitle: @escaping @Sendable () -> String,
        isAvailable: @escaping @Sendable (UserDefaults) -> Bool
    ) -> CommandPaletteSettingToggleDescriptor {
        CommandPaletteSettingToggleDescriptor(
            commandId: commandIdPrefix + "showAgentUsageInSidebar",
            settingsKey: "sidebar.showAgentUsage",
            title: {
                String(localized: "settings.app.showAgentUsage", defaultValue: "Show Agent Usage in Sidebar")
            },
            sectionTitle: sectionTitle,
            keywords: ["sidebar.showAgentUsage", "sidebar", "agent", "usage", "model", "context", "tokens", "cost"],
            defaultValue: SidebarWorkspaceDetailDefaults.showAgentUsage,
            defaultsKey: SidebarWorkspaceDetailDefaults.showAgentUsageKey,
            isAvailable: { defaults in
                isAvailable(defaults)
                    && UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.showCustomMetadata)
            }
        )
    }
}
