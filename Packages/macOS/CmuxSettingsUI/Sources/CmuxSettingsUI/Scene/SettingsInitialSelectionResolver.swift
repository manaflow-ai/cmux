import Foundation

struct SettingsInitialSelectionResolver {
    let defaults: UserDefaults

    func resolve(
        initialNavigationSection: SettingsSectionID?
    ) -> (sectionRawValue: String, sidebarEntryID: String) {
        if let initialNavigationSection {
            return (
                sectionRawValue: initialNavigationSection.rawValue,
                sidebarEntryID: "section:\(initialNavigationSection.rawValue)"
            )
        }
        let sectionRawValue = defaults.string(forKey: "selectedSettingsSection")
            ?? SettingsSectionID.account.rawValue
        let section = SettingsSectionID(rawValue: sectionRawValue) ?? .account
        let sidebarEntryID = defaults.string(forKey: "selectedSettingsSidebarEntry")
            ?? "section:\(section.rawValue)"
        return (sectionRawValue: section.rawValue, sidebarEntryID: sidebarEntryID)
    }
}
