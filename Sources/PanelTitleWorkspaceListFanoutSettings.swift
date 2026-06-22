import CmuxSettings

enum PanelTitleWorkspaceListFanoutSettings {
    static func isEnabled(settings: any SettingsReading) -> Bool {
        settings.value(for: SettingCatalog().terminal.titleUpdateWorkspaceListFanoutEnabled)
    }
}
