/// `remote.*` in cmux.json: cmux Remote, the one signed process that holds the macOS grants
/// for Computer Use and Screen Sharing (docs/cmux-remote.md).
/// - `headless` (on by default): this Mac keeps sharing its screen through the device hub
///   while cmux is quit. Off, a session ends when cmux quits.
public nonisolated struct RemoteSettings: Sendable, Equatable {
    public static let headlessPath = ["remote", "headless"]
    public var headless = true

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["remote"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("headless") { settings.headless = value }
        diagnostics = reader.diagnostics
        return settings
    }
}

/// General > Screen Sharing.
nonisolated enum RemoteSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.cmuxRemote", "Screen Sharing")
        return [
            SettingDescriptor(
                RemoteSettings.headlessPath, section: .general, group: group,
                title: SettingsText.keyed("settings.remote.headless", "Keep Sharing When cmux Is Quit"),
                help: SettingsText.keyed("settings.remote.headless.help",
                                         "cmux Remote keeps this Mac available to your devices and shows their requests while cmux is quit. Off, a session ends when cmux quits."),
                summary: SettingsText.keyed("settings.remote.headless.summary", "This Mac stays shared while cmux is quit"),
                kind: .toggle, default: .bool(RemoteSettings().headless),
                keywords: ["cmux remote", "screen sharing", "mac screen", "headless", "quit", "background", "device hub"]
            ),
        ]
    }
}
