import CmuxSettings

extension CmuxSettingsFileStore {
    /// Parses the settings-owned keys of the `rightSidebar` object.
    ///
    /// The same object also carries legacy and extension-owned configuration,
    /// so unknown keys are left alone instead of being reported as invalid.
    func parseRightSidebarSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let key = SettingCatalog().rightSidebar.toggleButton
        guard section.keys.contains("toggleButton") else { return }
        guard let raw = jsonString(section["toggleButton"]),
              let placement = RightSidebarToggleButtonPlacement(rawValue: raw) else {
            logInvalid(key.id, sourcePath: sourcePath)
            return
        }
        snapshot.managedUserDefaults[key.userDefaultsKey] = .string(placement.rawValue)
    }
}
