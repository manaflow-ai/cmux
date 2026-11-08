import CmuxSettings

extension CmuxSettingsFileStore {
    func parseSidebarIndicatorPositionSettings(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        parseSidebarIndicatorPositionSetting(
            section,
            jsonKey: "loadingSpinnerPosition",
            settingsPath: "sidebar.loadingSpinnerPosition",
            defaultsKey: SidebarCatalogSection().loadingSpinnerPosition.userDefaultsKey,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseSidebarIndicatorPositionSetting(
            section,
            jsonKey: "notificationBadgePosition",
            settingsPath: "sidebar.notificationBadgePosition",
            defaultsKey: SidebarCatalogSection().notificationBadgePosition.userDefaultsKey,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
    }

    private func parseSidebarIndicatorPositionSetting(
        _ section: [String: Any],
        jsonKey: String,
        settingsPath: String,
        defaultsKey: String,
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard let raw = jsonString(section[jsonKey]) else { return }
        guard let value = SidebarIndicatorPosition.decodeFromJSON(raw) else {
            logInvalid(settingsPath, sourcePath: sourcePath)
            return
        }
        snapshot.managedUserDefaults[defaultsKey] = .string(value.rawValue)
    }
}
