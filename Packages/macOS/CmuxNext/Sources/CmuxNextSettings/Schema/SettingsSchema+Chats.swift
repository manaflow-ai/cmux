/// Device-local chat indexing controls; all three keys are privacy decisions for the person.
nonisolated struct ChatSettingsSchema {
    var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.chats", "Chats")
        return [
            SettingDescriptor(["agents", "chats", "enabled"], section: .general, group: group,
                title: SettingsText.keyed("settings.chats.enabled", "Enable Chats"),
                help: SettingsText.keyed("settings.chats.enabled.help", "Show chats stored on this device. Nothing is uploaded."),
                kind: .toggle, default: .bool(true), keywords: ["agents", "chats", "privacy"]),
            SettingDescriptor(["agents", "chats", "discovery"], section: .general, group: group,
                title: SettingsText.keyed("settings.chats.discovery", "Discover Chat Folders"),
                help: SettingsText.keyed("settings.chats.discovery.help", "Find harness chat folders automatically. When off, only the listed folders are used."),
                kind: .toggle, default: .bool(true), keywords: ["agents", "chats", "discovery", "privacy"]),
            SettingDescriptor(ChatSettings.rootsPath, section: .general, group: group,
                title: SettingsText.keyed("settings.chats.roots", "Chat Folders"),
                help: SettingsText.keyed("settings.chats.roots.help", "Add absolute paths to harness data folders. Protected folders are refused. Your organization can add locked folders."),
                kind: .folderList, default: .array([]), keywords: ["agents", "chats", "folders", "roots", "privacy"]),
        ]
    }
}
