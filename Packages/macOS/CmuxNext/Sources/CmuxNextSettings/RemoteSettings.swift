/// `remote.*` in cmux.json: cmux Remote, the one signed process that holds the macOS grants
/// for Computer Use and Screen Sharing (docs/cmux-remote.md).
/// - `enabled` (off by default): the cmux-tui daemon runs cmux Remote. Computer Use with the
///   Upstream driver runs in it, and it serves this Mac's Screen Sharing, so a grant needs no
///   relaunch. Off, nothing changes: the app's own helper and host serve as before.
/// - `endSharingOnQuit` (off by default): a Screen Sharing session ends when cmux quits. Off,
///   cmux Remote keeps this Mac available to the person's devices while cmux is quit.
public nonisolated struct RemoteSettings: Sendable, Equatable {
    public static let enabledPath = ["remote", "enabled"]
    public static let endSharingOnQuitPath = ["remote", "endSharingOnQuit"]
    public var enabled = false
    public var endSharingOnQuit = false

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["remote"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
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
                RemoteSettings.enabledPath, section: .general, group: group,
                title: SettingsText.keyed("settings.remote.enabled", "Use cmux Remote"),
                help: SettingsText.keyed("settings.remote.enabled.help",
                                         "cmux Remote holds Accessibility and Screen Recording for Computer Use (Upstream driver) and Screen Sharing, so a grant never needs a relaunch. Applies when cmux restarts."),
                summary: SettingsText.keyed("settings.remote.enabled.summary", "One helper holds Computer Use and Screen Sharing permissions"),
                kind: .toggle, default: .bool(RemoteSettings().enabled),
                keywords: ["cmux remote", "computer use", "screen sharing", "mac screen", "accessibility", "screen recording", "permissions"]
            ),
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
