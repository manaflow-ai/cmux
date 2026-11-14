public import CmuxNextDesign
/// The Appearance section's Sidebar group (plans/cmux-next/sidebar-sections.md 7), in display order:
/// the rows generated from schemas/settings/source/sidebar.json (`SidebarSettingsSchema`), around
/// the rows other sources still define.
/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum SidebarSectionSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let sidebar = SettingsText.keyed("settings.group.sidebar", "Sidebar")
        return [SidebarSurfaceSetting.descriptor(group: sidebar)] + SidebarSettingsSchema.sidebar
            + [WorkspaceColorsSetting.indicatorStyleDescriptor(group: sidebar)] + SidebarSettingsSchema.sidebar2 + [
                ChromePlacementSetting.sidebarSideDescriptor(group: sidebar),
                ChromePlacementSetting.spacesPositionDescriptor(group: sidebar),
                ChromePlacementSetting.spacesVisibilityDescriptor(group: sidebar),
            ] + SidebarSettingsSchema.sidebar3
    }
}
