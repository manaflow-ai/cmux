import CmuxNextWakeups

/// The `energy.saver` row (``EnergySaverSetting``): Settings > General > Energy Saver. The page and
/// the palette leave it out while the `energySaver` feature is off, and leave out "On Battery" on a
/// Mac with no battery (``EnergySaverSetting/availability(featureEnabled:hasBattery:)``).
nonisolated enum EnergySettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.energy", "Energy Saver")
        return [
            SettingDescriptor(
                EnergySaverSetting.path, section: .general, group: group,
                title: SettingsText.keyed("settings.energy.saver", "Energy Saver"),
                help: SettingsText.keyed(
                    "settings.energy.saver.help",
                    "Energy Saver makes cmux use less power: web pages you are not using draw at most 30 frames per second, background animations stop, and timers and background checks run less often. Typing, scrolling and the animations you start are not slowed. Automatic: on in Low Power Mode, on battery below 20%, or on battery while the Mac is hot. On Battery: on whenever the Mac runs on battery. Always: always on. Off: never on. Turn Off for Now keeps it off until you plug in the Mac or change this setting."),
                summary: SettingsText.keyed("settings.energy.saver.summary", "Use less power on battery and in Low Power Mode"),
                kind: .choice([
                    SettingChoice(EnergySaverMode.auto.rawValue, SettingsText.keyed("settings.choice.energy.auto", "Automatic")),
                    SettingChoice(EnergySaverMode.onBattery.rawValue, SettingsText.keyed("settings.choice.energy.onBattery", "On Battery")),
                    SettingChoice(EnergySaverMode.always.rawValue, SettingsText.keyed("settings.choice.always", "Always")),
                    SettingChoice(EnergySaverMode.off.rawValue, SettingsText.keyed("settings.choice.off", "Off")),
                ]),
                default: .string(EnergySaverSetting.defaultValue.rawValue),
                keywords: ["energy", "energy saver", "battery", "battery saver", "power", "low power mode", "thermal",
                           "hot", "fan", "frame rate", "save power"]
            ),
        ]
    }
}
