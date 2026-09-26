import Foundation

extension CommandPaletteSettingsToggleCommands {
    /// The palette toggle for `sidebar.showAgentUsage`, kept out of the
    /// length-budgeted descriptor table. It shares the sidebar-details
    /// availability rule, so it is hidden while "Hide All Details" is on.
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
            isAvailable: isAvailable
        )
    }
}
