/// `remote.*` in cmux.json: cmux Remote, the one signed process that holds the macOS grants
/// for Computer Use and Screen Sharing (docs/cmux-remote.md).
/// The cmux-tui daemon runs cmux Remote whenever this build embeds it: Computer Use (the
/// Upstream driver) runs in it, and it serves this Mac's Screen Sharing, so a grant needs no
/// relaunch. A build without it uses the app's own helper and host.
/// - `endSharingOnQuit` (off by default): a Screen Sharing session ends when cmux quits. Off,
///   cmux Remote keeps this Mac available to the person's devices while cmux is quit.
public nonisolated struct RemoteSettings: Sendable, Equatable {
    public static let endSharingOnQuitPath = ["remote", "endSharingOnQuit"]
    public var endSharingOnQuit = false

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["remote"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("endSharingOnQuit") { settings.endSharingOnQuit = value }
        diagnostics = reader.diagnostics
        return settings
    }
}

/// Agents > cmux Remote.
nonisolated enum RemoteSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.cmuxRemote", "cmux Remote")
        return [
            SettingDescriptor(
                RemoteSettings.endSharingOnQuitPath, section: .general, group: group,
                title: SettingsText.keyed("settings.remote.endSharingOnQuit", "End Sharing When cmux Quits"),
                help: SettingsText.keyed("settings.remote.endSharingOnQuit.help",
                                         "Off, cmux Remote keeps this Mac available to your devices and shows their requests while cmux is quit."),
                summary: SettingsText.keyed("settings.remote.endSharingOnQuit.summary", "A session ends when cmux quits"),
                kind: .toggle, default: .bool(RemoteSettings().endSharingOnQuit),
                keywords: ["cmux remote", "screen sharing", "mac screen", "quit", "background", "device hub"]
            ),
        ]
    }
}
