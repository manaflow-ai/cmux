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

    /// Parses the sidebar-only shortcut hint appearance settings. The shared
    /// SwiftUI hint component keeps its pill default for non-sidebar callers.
    func parseSidebarShortcutHintSettings(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let sidebar = SidebarCatalogSection()
        if let raw = jsonString(section["shortcutHintStyle"]) {
            if let value = SidebarShortcutHintStyle.decodeFromJSON(raw) {
                snapshot.managedUserDefaults[sidebar.shortcutHintStyle.userDefaultsKey] = .string(value.rawValue)
            } else {
                logInvalid(sidebar.shortcutHintStyle.id, sourcePath: sourcePath)
            }
        }
        if section.keys.contains("shortcutHintColor") {
            guard let value = parseNullableHex(
                section["shortcutHintColor"],
                path: sidebar.shortcutHintColorHex.id,
                sourcePath: sourcePath
            ) else { return }
            snapshot.managedUserDefaults[sidebar.shortcutHintColorHex.userDefaultsKey] = .nullableString(value)
        }
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
