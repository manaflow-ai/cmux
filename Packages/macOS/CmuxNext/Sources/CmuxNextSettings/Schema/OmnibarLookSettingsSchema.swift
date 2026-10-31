import CmuxNextDesign

/// The Settings rows of the address bar's look (Browser > Address Bar,
/// cx-gkz5): the glass material, its tint from the terminal theme, the
/// corner radius, the shadow and the fill's opacity over a see-through
/// window (cx-d0d.101), and its height and text size. Looks only, so agents may change them.
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
                                         "The material of the address bar. Transparent draws no fill. Clear glass shows more of what is behind it. Off uses the flat theme color."),
                kind: .choice([
                    SettingChoice("transparent", SettingsText.keyed("settings.choice.transparent", "Transparent")),
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
            SettingDescriptor(
                S.backgroundOpacityPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.omnibar.backgroundOpacity", "Address Bar Opacity"),
                help: SettingsText.keyed("settings.browser.omnibar.backgroundOpacity.help",
                                         "How much the address bar covers a see-through window. At 0 it is as see-through as the window, but never so clear that its text stops being readable."),
                kind: .number(SettingNumber(0...1, step: 0.05, unit: .fraction)), default: .number(fallback.backgroundOpacity),
                keywords: ["opacity", "transparency", "background", "translucent", "address bar", "omnibox"]
            ),
        ] + sizeDescriptors
    }

    /// The bar's size (issue 28734): Match Density follows the density preset (Standard's
    /// 28 pt bar with 14 pt text, Comfortable's 34 pt with 15 pt), a number sets it.
    static var sizeDescriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.addressBar", "Address Bar")
        typealias S = BrowserOmnibarSetting
        let density = SettingChoice("density", SettingsText.keyed("settings.choice.matchDensity", "Match Density"))
        return [
            SettingDescriptor(
                S.heightPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.omnibar.height", "Address Bar Height"),
                help: SettingsText.keyed("settings.browser.omnibar.height.help",
                                         "Match Density follows the density. The bar always grows to fit its text."),
                kind: .choiceOrNumber([density], SettingNumber(S.heightRange, step: 1, unit: .points, placeholder: 28)),
                default: .string("density"), keywords: ["height", "size", "tall", "density", "address bar", "omnibox", "url"]
            ),
            SettingDescriptor(
                S.fontSizePath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.omnibar.fontSize", "Address Bar Text Size"),
                help: SettingsText.keyed("settings.browser.omnibar.fontSize.help",
                                         "The size of the address and the suggestions. Match Density follows the density."),
                kind: .choiceOrNumber([density], SettingNumber(S.fontSizeRange, step: 1, unit: .points, placeholder: 14)),
                default: .string("density"), keywords: ["font", "text", "size", "url", "density", "address bar", "omnibox"]
            ),
        ]
    }

    static var agentSettableKeys: Set<String> { Set(descriptors.map(\.id)) }
}
