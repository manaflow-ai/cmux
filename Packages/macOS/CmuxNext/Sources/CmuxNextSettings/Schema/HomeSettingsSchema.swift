import CmuxNextDesign

/// Settings > Home (the Home tab's conversations). One group of
/// `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum HomeSettingsSchema {
    /// Rows an agent may set (looks only): the Chief chat's bubble style.
    static let agentSettableKeys: Set<String> = [HomeChiefBubbleStyleSetting.key]

    static var descriptors: [SettingDescriptor] {
        let attachments = SettingsText.keyed("settings.group.attachments", "Attachments")
        return [
            // The Chief chat's look: iMessage's by default (the founders like its blue), the theme's on request (Leo 2026-10-19).
            SettingDescriptor(
                HomeChiefBubbleStyleSetting.configPath, section: .home, group: SettingsText.keyed("settings.group.chiefChat", "Chief Chat"),
                title: SettingsText.keyed("settings.home.chiefBubbleStyle", "Bubble Style"),
                help: SettingsText.keyed("settings.home.chiefBubbleStyle.help",
                                         "iMessage shows your messages in blue and the Chief's in gray. Theme uses your theme's accent and surface colors."),
                kind: .choice([
                    SettingChoice(HomeChiefBubbleStyleSetting.iMessage, "iMessage"), // a product name, not translated
                    SettingChoice(HomeChiefBubbleStyleSetting.theme, SettingsText.keyed("settings.choice.chiefBubbleStyle.theme", "Theme")),
                ]),
                default: .string(HomeChiefBubbleStyleSetting.defaultStyle),
                keywords: ["chief", "imessage", "messages", "bubbles", "blue", "chat", "theme", "colors", "home"]
            ),
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
        ]
    }
}
