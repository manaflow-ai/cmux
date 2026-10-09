public import CmuxNextDesign
/// Sidebar section settings (plans/cmux-next/sidebar-sections.md 7) in the
/// Appearance section's Sidebar group.
/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum SidebarSectionSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let sidebar = SettingsText.keyed("settings.group.sidebar", "Sidebar")
        let share = SettingNumber(SidebarSectionsPreferences.shareRange, step: 0.05, unit: .fraction)
        return [
            SettingDescriptor(
                SidebarBorderSetting.borderPath, section: .appearance, group: sidebar,
                title: SettingsText.keyed("settings.sidebar.border", "Border"),
                help: SettingsText.keyed("settings.sidebar.border.help",
                                        "A line on the sidebar's edge. Off, the edge shows a line only while you hover or drag it."),
                kind: .toggle, default: .bool(false), keywords: ["sidebar", "border", "edge", "line", "separator", "seam"]
            ),
            SettingDescriptor(
                SidebarBorderSetting.widthPath, section: .appearance, group: sidebar,
                title: SettingsText.keyed("settings.sidebar.borderWidth", "Border Width"),
                kind: .number(SettingNumber(Double(SidebarBorder.widthRange.lowerBound)...Double(SidebarBorder.widthRange.upperBound),
                                            step: 0.5, unit: .points, placeholder: 1)),
                default: nil, defaultLabel: SettingsText.keyed("settings.default.onePixel", "One pixel"),
                keywords: ["sidebar", "border", "edge", "line", "width", "thickness"]
            ),
            SettingDescriptor(
                SidebarSectionsSetting.lookPath, section: .appearance, group: sidebar,
                title: SettingsText.keyed("settings.sidebar.sectionLook", "Section Look"),
                help: SettingsText.keyed("settings.sidebar.sectionLook.help", "How the sections above and below the workspace list draw."),
                kind: .choice([
                    SettingChoice("quiet", SettingsText.keyed("settings.choice.sectionQuiet", "Quiet")),
                    SettingChoice("card", SettingsText.keyed("settings.choice.sectionCard", "Cards")),
                    SettingChoice("tray", SettingsText.keyed("settings.choice.sectionTray", "Tray")),
                    SettingChoice("lines", SettingsText.keyed("settings.choice.sectionLines", "Lines")),
                    SettingChoice("linesIcons", SettingsText.keyed("settings.choice.sectionLinesIcons", "Lines, Icons Only")),
                ]),
                default: .string(SidebarSectionsPreferences.defaults.look), keywords: ["sidebar", "sections", "home", "look", "style"]
            ),
            SettingDescriptor(
                SidebarSectionsSetting.topSharePath, section: .appearance, group: sidebar,
                title: SettingsText.keyed("settings.sidebar.topBandMaxShare", "Top Sections Height"),
                help: SettingsText.keyed("settings.sidebar.topBandMaxShare.help", "The share of the sidebar the top sections fill before they scroll."),
                kind: .number(share), default: .number(SidebarSectionsPreferences.defaults.topBandMaxShare),
                keywords: ["sidebar", "sections", "pinned", "height", "scroll"]
            ),
            SettingDescriptor(
                SidebarSectionsSetting.bottomSharePath, section: .appearance, group: sidebar,
                title: SettingsText.keyed("settings.sidebar.bottomBandMaxShare", "Bottom Sections Height"),
                help: SettingsText.keyed("settings.sidebar.bottomBandMaxShare.help", "The share of the sidebar the bottom sections fill before they scroll."),
                kind: .number(share), default: .number(SidebarSectionsPreferences.defaults.bottomBandMaxShare),
                keywords: ["sidebar", "sections", "pinned", "height", "scroll"]
            ),
            SettingDescriptor(
                SidebarSectionsSetting.scrollPath, section: .appearance, group: sidebar,
                title: SettingsText.keyed("settings.sidebar.pinnedBandsScroll", "Scroll Tall Sections"),
                help: SettingsText.keyed("settings.sidebar.pinnedBandsScroll.help",
                                        "Off: the top and bottom sections never scroll and the workspace list gets smaller."),
                kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.pinnedBandsScroll),
                keywords: ["sidebar", "sections", "pinned", "scroll"]
            ),
            SidebarSectionsSetting.showWorkspaceTabsDescriptor(group: sidebar),
            SidebarSectionsSetting.showChatsDescriptor(group: sidebar),
        ] + SidebarSectionsSetting.sectionDescriptors(group: sidebar) + [
            SidebarSectionsSetting.minimalModeDescriptor(group: sidebar),
            SidebarSectionsSetting.tipsDescriptor(group: sidebar),
            ChromePlacementSetting.sidebarSideDescriptor(group: sidebar),
            ChromePlacementSetting.spacesPositionDescriptor(group: sidebar),
            ChromePlacementSetting.spacesVisibilityDescriptor(group: sidebar),
        ] + SidebarNavigationSetting.descriptors(group: sidebar)
    }
}
