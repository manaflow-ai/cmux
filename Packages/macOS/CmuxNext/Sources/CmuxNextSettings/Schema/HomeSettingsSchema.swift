import CmuxNextDesign

/// Settings > Home (the Home tab's conversations). One group of
/// `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum HomeSettingsSchema {
    /// Rows an agent may set (looks only): the Chief chat's bubble style.
    static let agentSettableKeys: Set<String> = Set([HomeChiefBubbleStyleSetting.key]
        + HomeBubbleColorsSetting.roles.map { (HomeBubbleColorsSetting.configPath + [$0]).joined(separator: ".") })

    static var descriptors: [SettingDescriptor] {
        let attachments = SettingsText.keyed("settings.group.attachments", "Attachments")
        return [
            // Which server Home's direct messages and group chats use (dm-group-chat-DESIGN.md 4.5).
            SettingDescriptor(
                HomeServerSetting.configPath, section: .home,
                group: SettingsText.keyed("settings.group.messagesServer", "Messages Server"),
                title: SettingsText.keyed("settings.home.server", "Server"),
                help: SettingsText.keyed("settings.home.server.help",
                                         "Direct messages and group chats use cmux Cloud by default. A self-hosted server is reached over Tailscale by its MagicDNS name, for example http://mini.tail1234.ts.net:7320. No password is sent: the server knows you by your Tailscale login."),
                kind: .choiceOrURL([
                    SettingChoice(HomeServerSetting.hosted, SettingsText.keyed("settings.choice.homeServer.hosted", "cmux Cloud")),
                ], urlKey: HomeServerSetting.selfHostedKey),
                default: .string(HomeServerSetting.hosted),
                keywords: ["server", "self-hosted", "tailscale", "messages", "chat", "cloud", "home"]
            ),
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
            // The bubble colours every chat starts with (user 2026-10-28); a chat's Chat Colors… go over them.
            ] + bubbleColorRows + [
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
                HomeChiefPetSetting.configPath, section: .home, group: SettingsText.keyed("settings.group.chiefPet", "Chief Pet"),
                title: SettingsText.keyed("settings.home.chiefPetEnabled", "Show Chief Pet"),
                help: SettingsText.keyed("settings.home.chiefPetEnabled.help",
                                         "A small Chief floats over every app and shows agent events above it. Drag it anywhere; click it to message the Chief or reply to a session. While it shows, ⌃⌥⌘C opens its reply box from any app."),
                kind: .toggle, default: .bool(false), keywords: ["chief", "pet", "mascot", "floating", "notifications", "reply", "dock"]
            ),
            SettingDescriptor(
                HomeChiefPetSetting.mascotPath, section: .home, group: SettingsText.keyed("settings.group.chiefPet", "Chief Pet"),
                title: SettingsText.keyed("settings.home.chiefPetMascot", "Character"),
                kind: .choice([
                    SettingChoice("orb", SettingsText.keyed("settings.choice.chiefPetMascot.orb", "Orb")),
                    SettingChoice("orb-spark", SettingsText.keyed("settings.choice.chiefPetMascot.orb-spark", "Orb Spark")),
                    SettingChoice("orb-hood", SettingsText.keyed("settings.choice.chiefPetMascot.orb-hood", "Hooded Orb")),
                    SettingChoice("machine", SettingsText.keyed("settings.choice.chiefPetMascot.machine", "Machine")),
                    SettingChoice("machine-cyan", SettingsText.keyed("settings.choice.chiefPetMascot.machine-cyan", "Cyan Machine")),
                    SettingChoice("machine-blue", SettingsText.keyed("settings.choice.chiefPetMascot.machine-blue", "Blue Machine")),
                    SettingChoice("moon", SettingsText.keyed("settings.choice.chiefPetMascot.moon", "Moon")),
                    SettingChoice("moon-blue", SettingsText.keyed("settings.choice.chiefPetMascot.moon-blue", "Blue Moon")),
                    SettingChoice("fox", SettingsText.keyed("settings.choice.chiefPetMascot.fox", "Fox")),
                    SettingChoice("mochi", SettingsText.keyed("settings.choice.chiefPetMascot.mochi", "Mochi")),
                ]),
                default: .string(HomeChiefPetSetting.defaultMascot), keywords: ["chief", "pet", "mascot", "character", "avatar", "pixel"]
            ),
            // Settings > Chief's Chiefs card draws it as its Engine row (ChiefsCard.tsx).
            SettingDescriptor(
                HomeChiefEngineSetting.configPath, section: .home, group: SettingsText.keyed("settings.group.chiefEngine", "Engine"),
                title: SettingsText.keyed("settings.home.chiefEngine", "Engine"),
                help: SettingsText.keyed("settings.home.chiefEngine.help",
                                         "Which Chief Home opens. Auto uses this Mac's Chief while it runs here, else the Hosted Chief in the cloud."),
                kind: .choice([
                    SettingChoice("auto", SettingsText.keyed("settings.choice.chiefEngine.auto", "Auto")),
                    SettingChoice("local", SettingsText.keyed("settings.choice.chiefEngine.local", "This Mac")),
                    SettingChoice("hosted", SettingsText.keyed("settings.choice.chiefEngine.hosted", "Hosted")),
                ]),
                default: .string(HomeChiefEngineSetting.defaultEngine), keywords: ["chief", "engine", "backend", "hosted", "cloud", "local", "optchat"]
            ),
        ]
    }

    /// `home.bubbleColors.*`: one colour row per role; unset keeps the bubble style's colour.
    private static var bubbleColorRows: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.chiefChat", "Chief Chat")
        let style = SettingsText.keyed("settings.home.bubbleColors.default", "Bubble Style")
        let rows: [(String, SettingText)] = [
            ("sent", SettingsText.keyed("settings.home.bubbleColors.sent", "My Bubble Color")),
            ("sentText", SettingsText.keyed("settings.home.bubbleColors.sentText", "My Text Color")),
            ("received", SettingsText.keyed("settings.home.bubbleColors.received", "Their Bubble Color")),
            ("receivedText", SettingsText.keyed("settings.home.bubbleColors.receivedText", "Their Text Color")),
        ]
        return rows.map { role, title in
            SettingDescriptor(
                HomeBubbleColorsSetting.configPath + [role], section: .home, group: group, title: title,
                help: SettingsText.keyed("settings.home.bubbleColors.help",
                                         "Every chat starts with these colors. Right-click a chat and choose Chat Colors to set its own. Unset text colors are picked to stay readable."),
                kind: .color, default: nil, defaultLabel: style,
                keywords: ["bubble", "color", "text", "imessage", "chat", "messages", "background", "home"]
            )
        }
    }
}
