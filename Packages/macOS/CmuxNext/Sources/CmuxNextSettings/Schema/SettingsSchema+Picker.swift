extension SettingsSchema {
    /// The cmux picker (R89, plans/cmux-next/picker.md): folders it lists
    /// under Locations. Parsed by ``PickerPinnedSetting``.
    static var picker: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.picker", "Folder Picker")
        return [
            SettingDescriptor(
                PickerPinnedSetting.configPath, section: .general, group: group,
                title: SettingsText.keyed("settings.picker.pinned", "Pinned Folders"),
                help: SettingsText.keyed("settings.picker.pinned.help",
                                        "The picker lists these folders under Locations, after Home and Downloads. Use full paths or ~/ paths."),
                kind: .folderList, default: .array([]),
                keywords: ["picker", "pinned", "folders", "locations", "open", "save"]
            ),
        ]
    }
}
