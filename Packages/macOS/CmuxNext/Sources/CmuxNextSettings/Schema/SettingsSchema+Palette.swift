/// Palette scope prefixes (`palette.scopes.<scope>.prefix`), in the
/// General section's Command Palette group.
/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum PaletteSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.palette", "Command Palette")
        let help = SettingsText.keyed("settings.palette.prefix.help",
                                      "Typed into an empty query, this character enters the scope. A prefix you assign moves from any other scope.")
        let none = SettingsText.keyed("settings.choice.prefixNone", "None")
        let choices = PaletteScopePrefixes.characters.map { SettingChoice($0, $0) } + [SettingChoice(PaletteScopePrefixes.noneValue, none)]
        return PaletteScopePrefixes.defaults.map { scope, prefix in
            SettingDescriptor(
                PaletteScopePrefixes.path(scope), section: .general, group: group, title: title(scope), help: help,
                kind: .choice(choices), default: .string(prefix), keywords: ["palette", "prefix", "scope", scope]
            )
        }
    }

    private static func title(_ scope: String) -> SettingText {
        switch scope {
        case "tabs": SettingsText.keyed("settings.palette.prefix.tabs", "Tabs Prefix")
        case "workspaces": SettingsText.keyed("settings.palette.prefix.workspaces", "Workspaces Prefix")
        case "commands": SettingsText.keyed("settings.palette.prefix.commands", "Commands Prefix")
        case "settings": SettingsText.keyed("settings.palette.prefix.settings", "Settings Prefix")
        default: SettingsText.keyed("settings.palette.prefix.scopes", "Scope List Prefix")
        }
    }
}
