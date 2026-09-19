import Foundation

extension CommandPaletteSettingsToggleCommands {
    static func pullRequestChecksToggle(
        section: @escaping @Sendable () -> String,
        isAvailable: @escaping @Sendable (UserDefaults) -> Bool
    ) -> CommandPaletteSettingToggleDescriptor {
        CommandPaletteSettingToggleDescriptor(
            commandId: commandIdPrefix + "showPullRequestChecks",
            settingsKey: "sidebar.showPullRequestChecks",
            title: { String(localized: "settings.app.showPullRequestChecks", defaultValue: "Show Pull Request Checks") },
            sectionTitle: section,
            keywords: ["sidebar.showPullRequestChecks", "sidebar", "pr", "ci", "checks", "tests"],
            defaultValue: SidebarWorkspaceDetailDefaults.showPullRequestChecks,
            defaultsKey: SidebarWorkspaceDetailDefaults.showPullRequestChecksKey,
            isAvailable: { defaults in
                isAvailable(defaults) && SidebarWorkspaceDetailDefaults.showPullRequestsValue(defaults: defaults)
            }
        )
    }
}
