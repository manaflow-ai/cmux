import CmuxNextDesign

extension SettingsSchema {
    /// Settings > Advanced > Labs: surfaces still being shaped, off by default.
    static var labs: [SettingDescriptor] {
        let labs = SettingsText.keyed("settings.group.labs", "Labs")
        return [
            SettingDescriptor(
                CmuxConfigSnapshot.previewFeaturesPath, section: .advanced, group: labs,
                title: SettingsText.keyed("settings.labs.previewFeatures", "Show Preview Features"),
                help: SettingsText.keyed("settings.labs.previewFeatures.help", "Unfinished surfaces, such as the agent session's coverage label and Pull requests view."),
                kind: .toggle, default: .bool(false), keywords: ["labs", "preview", "experimental", "beta", "prototype"]
            ),
        ]
    }
}
