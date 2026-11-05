import CmuxNextDesign

/// The tab size, overflow and width rows of the Tabs group (`appearance.metrics.tabFontSize` and `tabStripHeight`,
/// https://github.com/manaflow-ai/cmux/issues/26493; `tabs.overflow`, `appearance.metrics.tabMaxWidth`, `tabMinActiveWidth`,
/// `tabMinInactiveWidth`, `tabPinnedWidth`; Lawrence 2026-10-15: "keep chrome's minimums but needs to
/// be customizable"). Unset means the density's value from the shared tokens; the strip keeps
/// min <= max. Its own type: the schema type's line budget is per type.
nonisolated enum TabWidthSettingsSchema {
    static func descriptors(group: SettingText) -> [SettingDescriptor] {
        let densityDefault = SettingsText.keyed("settings.default.density", "Density default")
        return [
            row(.tabFontSize, group, SettingsText.keyed("settings.tabs.tabFontSize", "Tab Text Size"),
                SettingsText.keyed("settings.tabs.tabFontSize.help", "Text size of tab titles. Unset, tabs follow the interface size."),
                SettingsText.keyed("settings.tabs.tabFontSize.default", "Interface size"),
                keywords: ["tab", "tabs", "font", "text", "size", "title", "bigger", "smaller", "readable", "tabFontSize"]),
            row(.tabStripHeight, group, SettingsText.keyed("settings.tabs.tabStripHeight", "Tab Bar Height"),
                SettingsText.keyed("settings.tabs.tabStripHeight.help", "Height of a pane's tab bar. Its tabs grow and shrink with it."),
                densityDefault, keywords: ["tab", "tabs", "bar", "strip", "height", "size", "taller", "tabStripHeight"]),
            // Shrink (Chrome's) or Scroll (cx-kp9b4): the palette's Tabs: Use Scrolling Tabs and Tabs: Use
            // Shrinking Tabs write it. Either way a crowded strip scrolls; it never asks.
            SettingDescriptor(
                TabOverflowSetting.configPath, section: .general, group: group,
                title: SettingsText.keyed("settings.tabs.overflow", "Tab Overflow"),
                help: SettingsText.keyed("settings.tabs.overflow.help",
                                         "Shrink narrows every tab to the minimum width before the strip scrolls. Scroll keeps tabs wide and scrolls sooner."),
                kind: .choice([
                    SettingChoice(TabOverflow.shrink.rawValue, SettingsText.keyed("settings.choice.tabOverflowShrink", "Shrink")),
                    SettingChoice(TabOverflow.scroll.rawValue, SettingsText.keyed("settings.choice.tabOverflowScroll", "Scroll")),
                ]),
                default: .string(TabOverflowSetting.fallback.rawValue),
                keywords: ["tab", "tabs", "overflow", "scroll", "scrolling", "shrink", "crowded", "width", "many"]
            ).consumed(by: [.cmuxNext]),
            row(.tabMaxWidth, group, SettingsText.keyed("settings.tabs.tabMaxWidth", "Maximum Tab Width"),
                SettingsText.keyed("settings.tabs.tabMaxWidth.help", "Widest a tab gets when the strip has room."),
                densityDefault, keywords: ["tab", "width", "max", "maximum", "wide", "tabMaxWidth"]),
            row(.tabMinActiveWidth, group, SettingsText.keyed("settings.tabs.tabMinActiveWidth", "Minimum Selected Tab Width"),
                SettingsText.keyed("settings.tabs.tabMinActiveWidth.help",
                                   "When the strip is crowded, every tab shrinks evenly to this width, and the selected tab stays at least this wide."),
                densityDefault, keywords: ["tab", "width", "min", "minimum", "selected", "active", "crowded", "narrow", "tabMinActiveWidth"]),
            row(.tabMinInactiveWidth, group, SettingsText.keyed("settings.tabs.tabMinInactiveWidth", "Minimum Tab Width"),
                SettingsText.keyed("settings.tabs.tabMinInactiveWidth.help",
                                   "Narrowest the other tabs get before the strip scrolls. Never wider than the selected tab's minimum."),
                densityDefault, keywords: ["tab", "width", "min", "minimum", "inactive", "crowded", "narrow", "scroll", "tabMinInactiveWidth"]),
            row(.tabPinnedWidth, group, SettingsText.keyed("settings.tabs.tabPinnedWidth", "Pinned Tab Width"),
                SettingsText.keyed("settings.tabs.tabPinnedWidth.help", "Width of a pinned tab."),
                densityDefault, keywords: ["tab", "width", "pinned", "pin", "tabPinnedWidth"]),
        ]
    }

    private static func row(_ metric: LayoutMetricSetting, _ group: SettingText, _ title: SettingText, _ help: SettingText, _ densityDefault: SettingText,
                            keywords: [String]) -> SettingDescriptor {
        SettingDescriptor(
            metric.configPath, section: .general, group: group, title: title, help: help,
            kind: .number(SettingNumber(metric.range, step: 1, unit: .points, placeholder: metric.compact)),
            default: nil, defaultLabel: densityDefault, keywords: keywords
        ).consumed(by: [.cmuxNext])
    }
}
