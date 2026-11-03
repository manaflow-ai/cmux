/// The `imessage.enabled` row in cmux.json: the opt-in Messages mirror (the Messages Mirror page),
/// Settings > Privacy and Security > Messages. Off by default. On, cmux's daemon reads this Mac's
/// Messages database, read only, for that page; nothing is copied, synced or sent anywhere. The
/// daemon reads the key itself and treats anything but a literal `true` as off, so Swift only
/// declares the row. Agents may not change it (`.userOnly`).
nonisolated enum ImessageMirrorSettingsSchema {
    /// The cmux.json key path.
    static let enabledPath = ["imessage", "enabled"]

    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.imessage", "Messages")
        return [
            SettingDescriptor(
                enabledPath, section: .home, group: group,
                title: SettingsText.keyed("settings.imessage.enabled", "Mirror Messages (local only)"),
                help: SettingsText.keyed(
                    "settings.imessage.enabled.help",
                    "Shows your Messages conversations in cmux, read only. cmux reads the Messages database on this Mac; nothing is copied, synced or sent anywhere. macOS asks you to give cmux Full Disk Access first."),
                summary: SettingsText.keyed("settings.imessage.enabled.summary", "Shows your Messages conversations in cmux"),
                kind: .toggle, default: .bool(false),
                keywords: ["imessage", "messages", "sms", "texts", "mirror", "chats", "full disk access", "privacy"]
            ),
        ]
    }
}
