/// `remote.*` in cmux.json: cmux Remote, the one signed process that holds the macOS grants
/// for Computer Use and Screen Sharing (docs/cmux-remote.md).
/// The cmux-tui daemon runs cmux Remote whenever this build embeds it: Computer Use (the
/// Upstream driver) runs in it, and it serves this Mac's Screen Sharing, so a grant needs no
/// relaunch. A build without it uses the app's own helper and host.
/// - `endSharingOnQuit` (off by default): a Screen Sharing session ends when cmux quits. Off,
///   cmux Remote keeps this Mac available to the person's devices while cmux is quit.
/// - `ultraMode` (off by default): Ultra Connection Mode. The Rust tunnel starts read it from the
///   file themselves (cmux-tui-util `user_settings::ultra_mode`); kept here so the row reads back.
public nonisolated struct RemoteSettings: Sendable, Equatable {
    public var endSharingOnQuit = RemoteSettings.endSharingOnQuitDefault
    public var ultraMode = RemoteSettings.ultraModeDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["remote"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("endSharingOnQuit") { settings.endSharingOnQuit = value }
        if let value = reader.bool("ultraMode") { settings.ultraMode = value }
        diagnostics = reader.diagnostics
        return settings
    }
}
