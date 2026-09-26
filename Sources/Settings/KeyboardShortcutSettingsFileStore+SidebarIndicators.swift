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

    /// Parses `sidebar.density`, which supplies defaults for the sidebar detail
    /// toggles that are not set explicitly.
    func parseSidebarDensitySetting(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard section.keys.contains("density") else { return }
        guard let raw = jsonString(section["density"]),
              let value = SidebarDensity.decodeFromJSON(raw) else {
            logInvalid("sidebar.density", sourcePath: sourcePath)
            return
        }
        snapshot.managedUserDefaults[SidebarCatalogSection().density.userDefaultsKey] = .string(value.rawValue)
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
