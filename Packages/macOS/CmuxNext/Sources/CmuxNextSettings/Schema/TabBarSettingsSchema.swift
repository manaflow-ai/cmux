/// The tab bar placement rows of the Tabs group (R109): `tabs.barPosition`
/// and `tabs.barOrder`. Its own type: the schema type's line budget is per type.
nonisolated enum TabBarSettingsSchema {
    static func descriptors(group: SettingText) -> [SettingDescriptor] {
        [
            ChromePlacementSetting.tabBarPositionDescriptor(group: group),
            ChromePlacementSetting.tabBarOrderDescriptor(group: group),
        ]
    }
}
