public import CmuxNextDesign
/// Sidebar section settings (plans/cmux-next/sidebar-sections.md 7) in the
/// Appearance section's Sidebar group.
extension SettingsSchema {
    static var sidebarSections: [SettingDescriptor] {
        let sidebar = SettingsText.keyed("settings.group.sidebar", "Sidebar")
        let share = SettingNumber(SidebarSectionsPreferences.shareRange, step: 0.05, unit: .fraction)
        return [
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
            SidebarSectionsSetting.minimalModeDescriptor(group: sidebar),
        ]
    }
}
