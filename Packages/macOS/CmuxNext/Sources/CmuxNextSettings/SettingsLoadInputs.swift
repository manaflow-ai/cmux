import CmuxNextDesign

/// Everything a settings load depends on. An unchanged input skips the apply.
nonisolated struct SettingsLoadInputs: Equatable, Sendable {
    let source: String
    let managed: ManagedPreferences
    let team: TeamPolicyLayer
    let sidebarLookGroupBackground: JSONValue?
    var themeFile: ThemeFile?

    /// The active theme file's name and text (nil text: missing or unreadable).
    nonisolated struct ThemeFile: Equatable, Sendable {
        let name: String
        let source: String?
    }

    func sidebarLookOverridesDefault(for key: String) -> Bool {
        guard key == SidebarSectionsSetting.groupHeaderBackgroundPath.joined(separator: "."),
              let sidebarLookGroupBackground else { return false }
        return sidebarLookGroupBackground != .string(SidebarSectionsSetting.groupHeaderBackgroundDefault.rawValue)
    }
}
