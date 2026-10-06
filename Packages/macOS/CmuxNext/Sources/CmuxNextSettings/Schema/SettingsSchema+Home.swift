import CmuxNextDesign

/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum HomeSettingsSchema {
    /// Settings > Home (the Home tab's conversations).
    static var descriptors: [SettingDescriptor] {
        let attachments = SettingsText.keyed("settings.group.attachments", "Attachments")
        return [
            SettingDescriptor(
                HomeKeepLocationSetting.configPath, section: .home, group: attachments,
                title: SettingsText.keyed("settings.home.keepLocation", "Keep Location in Photos and Videos"),
                help: SettingsText.keyed("settings.home.keepLocation.help",
                                         "When off, location data is removed from photos and videos before they are attached."),
                kind: .toggle, default: .bool(false), keywords: ["gps", "location", "privacy", "metadata", "exif", "attachments", "photos"]
            ),
        ]
    }
}
