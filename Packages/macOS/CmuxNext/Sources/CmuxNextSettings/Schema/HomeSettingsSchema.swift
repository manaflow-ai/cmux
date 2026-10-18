import CmuxNextDesign

/// Settings > Home (the Home tab's conversations). One group of
/// `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum HomeSettingsSchema {
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
            // The Channels entry after Home (cx-frn2y): section Home; the Settings page draws it in the
            // Appearance category's Sidebar card (the card takes every row of the sidebar group).
            SettingDescriptor(
                HomeChannelsSetting.configPath, section: .home, group: SettingsText.keyed("settings.group.sidebar", "Sidebar"),
                title: SettingsText.keyed("settings.home.channelsEnabled", "Channels"),
                help: SettingsText.keyed("settings.home.channelsEnabled.help",
                                         "Show Channels below Home in the sidebar. You can also turn it on or off from the command palette."),
                kind: .toggle, default: .bool(false), keywords: ["home", "channels", "slack", "threads", "sidebar", "messages"]
            ),
            SettingDescriptor(
                BackdropPlaybackConfigParser.chiefPictureMotionPath, section: .home,
                group: SettingsText.keyed("settings.group.chiefPictures", "Chief Pictures"),
                title: SettingsText.keyed("settings.home.chiefPictureMotion", "Animated Pictures"),
                help: SettingsText.keyed("settings.home.chiefPictureMotion.help",
                                         "Whether a Chief's GIF or animated picture moves on Home pages. Reduce Motion always shows its first frame."),
                kind: .choice([
                    SettingChoice(ChiefPictureMotion.always.rawValue, SettingsText.keyed("settings.choice.always", "Always")),
                    SettingChoice(ChiefPictureMotion.hover.rawValue, SettingsText.keyed("settings.choice.onHover", "On Hover")),
                    SettingChoice(ChiefPictureMotion.never.rawValue, SettingsText.keyed("settings.choice.never", "Never")),
                ]),
                default: .string(ChiefPictureMotion.hover.rawValue), keywords: ["chief", "avatar", "picture", "gif", "animation", "motion"]
            ),
        ]
    }
}
