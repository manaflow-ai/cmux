/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum FeedSettingsSchema {
    /// GitHub inbox preferences under Notifications. The schema supplies the
    /// Settings window, palette setting editor, and validated config writes.
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.githubInbox", "GitHub Inbox")
        let defaults = FeedGitHubSettings()
        return [
            SettingDescriptor(
                FeedGitHubSettings.enabledPath, section: .notifications, group: group,
                title: SettingsText.keyed("settings.feed.github.enabled", "Connect GitHub"),
                help: SettingsText.keyed("settings.feed.github.enabled.help",
                                        "Uses your gh login to read notifications and review requests on this Mac. Sign in with gh auth login first."),
                kind: .toggle, default: .bool(defaults.enabled),
                keywords: ["github", "inbox", "review", "pull request", "connection", "gh"]
            ),
            SettingDescriptor(
                FeedGitHubSettings.pollIntervalPath, section: .notifications, group: group,
                title: SettingsText.keyed("settings.feed.github.pollInterval", "Refresh Interval"),
                help: SettingsText.keyed("settings.feed.github.pollInterval.help", "Seconds between GitHub refreshes. Refresh in the Inbox runs immediately."),
                kind: .number(SettingNumber(FeedGitHubSettings.pollIntervalRange, step: 30, unit: .seconds)),
                default: .number(defaults.pollIntervalSeconds), keywords: ["github", "inbox", "poll", "refresh", "interval"]
            ),
        ]
    }
}
