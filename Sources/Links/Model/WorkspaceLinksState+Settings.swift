import CmuxSettings

extension WorkspaceLinksState {
    convenience init(settings: any SettingsReading) {
        let linksCatalog = SettingCatalog().artifacts
        self.init(
            retentionLimit: settings.value(for: linksCatalog.retentionLimit),
            fetchTitlesEnabled: settings.value(for: linksCatalog.fetchTitles)
        )
    }
}
