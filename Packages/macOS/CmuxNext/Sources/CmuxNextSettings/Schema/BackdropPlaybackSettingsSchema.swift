import CmuxNextDesign

/// The Window Background rows for video playback and pane-aware framing (backgrounds plan phase 5).
/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum BackdropPlaybackSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.windowBackground", "Window Background")
        let defaults = BackdropPlaybackSettings()
        let path = BackdropPlaybackConfigParser.path
        return [
            SettingDescriptor(
                path + ["backgroundVideo"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.appearance.backgroundVideo", "Video Background"),
                help: SettingsText.keyed("settings.appearance.backgroundVideo.help",
                                        "A video background plays while you can see it. It pauses when hidden or covered, in Low Power Mode and with Reduce Motion."),
                kind: .choice([
                    SettingChoice(BackdropVideoMode.play.rawValue, SettingsText.keyed("settings.choice.backgroundVideo.play", "Play")),
                    SettingChoice(BackdropVideoMode.whenActive.rawValue,
                                  SettingsText.keyed("settings.choice.backgroundVideo.whenActive", "Only While cmux Is Active")),
                    SettingChoice(BackdropVideoMode.still.rawValue, SettingsText.keyed("settings.choice.backgroundVideo.still", "Still Picture")),
                ]),
                default: .string(defaults.video.rawValue), keywords: ["video", "wallpaper", "aerial", "motion", "play", "pause", "battery"]
            ),
            SettingDescriptor(
                path + ["backgroundVideoOnBattery"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.appearance.backgroundVideoOnBattery", "On Battery"),
                help: SettingsText.keyed("settings.appearance.backgroundVideoOnBattery.help",
                                        "Whether a video background keeps playing on battery. Low Power Mode always pauses it."),
                kind: .choice([
                    SettingChoice(BackdropBatteryMode.play.rawValue, SettingsText.keyed("settings.choice.backgroundVideoOnBattery.play", "Keep Playing")),
                    SettingChoice(BackdropBatteryMode.pause.rawValue, SettingsText.keyed("settings.choice.backgroundVideoOnBattery.pause", "Pause")),
                ]),
                default: .string(defaults.onBattery.rawValue), keywords: ["video", "battery", "power", "energy"]
            ),
            SettingDescriptor(
                path + ["backgroundAvoidPanes"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.appearance.backgroundAvoidPanes", "Keep Paintings Clear of Panes"),
                help: SettingsText.keyed("settings.appearance.backgroundAvoidPanes.help",
                                        "Frames a painting so its subject shows beside the sidebar and the agent chat, not under them."),
                kind: .toggle, default: .bool(defaults.avoidsPanes), keywords: ["painting", "crop", "subject", "framing", "sidebar", "agent"]
            ),
        ]
    }
}
