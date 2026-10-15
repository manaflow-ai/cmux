/// `mobile.*` in cmux.json: phones reaching this Mac. `allowIPhoneConnections`
/// (off by default) lets the app run its cmux iPhone host while an
/// account is signed in, so the cmux app on the same account's iPhone
/// can open this Mac's workspaces, terminals and agent chats. Only the
/// person turns it on (agent policy `userOnly`).
public nonisolated struct MobileSettings: Sendable, Equatable {
    public static let allowIPhoneConnectionsPath = ["mobile", "allowIPhoneConnections"]
    public var allowIPhoneConnections = false

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["mobile"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("allowIPhoneConnections") { settings.allowIPhoneConnections = value }
        diagnostics = reader.diagnostics
        return settings
    }
}

/// The Mobile settings rows (the Settings page's Mobile category).
nonisolated enum MobileSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.mobile", "iPhone")
        return [
            SettingDescriptor(
                MobileSettings.allowIPhoneConnectionsPath, section: .accounts, group: group,
                title: SettingsText.keyed("settings.mobile.allowIPhoneConnections", "Allow iPhone Connections"),
                help: SettingsText.keyed("settings.mobile.allowIPhoneConnections.help",
                                         "Lets the cmux app on your iPhone open this Mac's workspaces, terminals and agent chats while you are signed in with the same account."),
                summary: SettingsText.keyed("settings.mobile.allowIPhoneConnections.summary", "Lets your iPhone reach this Mac"),
                kind: .toggle, default: .bool(MobileSettings().allowIPhoneConnections),
                keywords: ["iphone", "phone", "mobile", "remote", "connect"]
            ),
        ]
    }
}
