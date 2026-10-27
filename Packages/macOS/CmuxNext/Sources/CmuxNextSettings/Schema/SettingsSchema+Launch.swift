/// The `launch.savedPicture` row (``LaunchSavedPictureSetting``): Settings > General > Launch. Off the Settings
/// page and the palette while the `savedWindowPicture` feature is off by default (the row would change nothing).
nonisolated enum LaunchSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.launch", "Launch")
        return [
            SettingDescriptor(
                LaunchSavedPictureSetting.path, section: .general, group: group,
                title: SettingsText.keyed("settings.launch.savedPicture", "Open Windows from a Saved Picture"),
                help: SettingsText.keyed(
                    "settings.launch.savedPicture.help",
                    "At quit, cmux saves a picture of each window on this Mac and shows it while the window opens next time. Pictures can show terminal text and web pages. Incognito windows, password entry and protected video are never saved. Off deletes the pictures."),
                summary: SettingsText.keyed("settings.launch.savedPicture.summary", "Windows appear at once when cmux opens"),
                kind: .toggle, default: .bool(LaunchSavedPictureSetting.defaultValue),
                keywords: ["launch", "startup", "start", "open", "fast", "picture", "snapshot", "screenshot", "restore", "privacy"]
            )
            .hiddenFromSettingsPage("behind the savedWindowPicture feature (off by default)"),
        ]
    }
}
