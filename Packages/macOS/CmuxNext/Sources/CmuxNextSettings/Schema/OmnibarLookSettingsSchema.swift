import CmuxNextDesign

/// The Settings rows of the address bar's look (Browser > Address Bar,
/// cx-gkz5): the glass material, its tint from the terminal theme, the
/// corner radius and the shadow. Looks only, so agents may change them.
nonisolated enum OmnibarLookSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.addressBar", "Address Bar")
        typealias S = BrowserOmnibarSetting
        let fallback = S.fallback
        return [
            SettingDescriptor(
                S.glassPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.omnibar.glass", "Address Bar Glass"),
                help: SettingsText.keyed("settings.browser.omnibar.glass.help",
                                         "The material of the address bar. Clear shows more of what is behind it. Off uses the flat theme color."),
                kind: .choice([
                    SettingChoice("regular", SettingsText.keyed("settings.choice.glass", "Glass")),
                    SettingChoice("clear", SettingsText.keyed("settings.choice.glassClear", "Clear Glass")),
                    SettingChoice("off", SettingsText.keyed("settings.choice.off", "Off")),
                ]),
                default: .string(fallback.glass), keywords: ["glass", "liquid glass", "material", "omnibox", "address bar", "blur"]
            ),
            SettingDescriptor(
                S.glassTintPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.omnibar.glassTint", "Glass Tint"),
                help: SettingsText.keyed("settings.browser.omnibar.glassTint.help",
                                         "The color over the glass, from the terminal theme. Accent is the theme's own accent color, or gray when the theme has none."),
                kind: .choice([
                    SettingChoice("background", SettingsText.keyed("settings.choice.themeBackground", "Theme Background")),
                    SettingChoice("accent", SettingsText.keyed("settings.choice.themeAccent", "Theme Accent")),
                    SettingChoice("none", SettingsText.keyed("settings.choice.none", "None")),
                ]),
                default: .string(fallback.glassTint), keywords: ["tint", "color", "glass", "theme", "address bar"]
            ),
            SettingDescriptor(
                S.glassTintStrengthPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.omnibar.glassTintStrength", "Tint Strength"),
                kind: .number(SettingNumber(0...1, step: 0.05, unit: .fraction)), default: .number(fallback.glassTintStrength),
                keywords: ["tint", "opacity", "glass", "address bar"]
            ),
            SettingDescriptor(
                S.cornerRadiusPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.omnibar.cornerRadius", "Address Bar Corners"),
                help: SettingsText.keyed("settings.browser.omnibar.cornerRadius.help",
                                         "Match Theme uses the standard bar radius. Capsule rounds the ends fully."),
                kind: .choiceOrNumber([
                    SettingChoice("theme", SettingsText.keyed("settings.choice.matchTheme", "Match Theme")),
                    SettingChoice("capsule", SettingsText.keyed("settings.choice.capsule", "Capsule")),
                ], SettingNumber(S.cornerRadiusRange, step: 1, unit: .points, placeholder: 8)),
                default: .string("theme"), keywords: ["corner", "radius", "rounded", "capsule", "pill", "address bar"]
            ),
            SettingDescriptor(
                S.shadowPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.omnibar.shadow", "Address Bar Shadow"),
                help: SettingsText.keyed("settings.browser.omnibar.shadow.help", "A soft shadow under the glass address bar."),
                kind: .toggle, default: .bool(fallback.shadow), keywords: ["shadow", "glass", "address bar"]
            ),
        ]
    }

    static var agentSettableKeys: Set<String> { Set(descriptors.map(\.id)) }
}
