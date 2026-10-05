import CmuxNextDesign

extension SettingsSchema {
    /// Settings > Home (the Home tab's conversations).
    static var home: [SettingDescriptor] {
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
