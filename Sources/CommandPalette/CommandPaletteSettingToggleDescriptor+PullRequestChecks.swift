import Foundation

extension CommandPaletteSettingToggleDescriptor {
    /// Creates the checks toggle with the sidebar’s visibility dependencies.
    init(
        pullRequestChecksIn section: @escaping @Sendable () -> String,
        isAvailable: @escaping @Sendable (UserDefaults) -> Bool
    ) {
        self.init(
            commandId: CommandPaletteSettingsToggleCommands.commandIdPrefix + "showPullRequestChecks",
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
