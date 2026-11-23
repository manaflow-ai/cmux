/// `remote.*` in cmux.json: cmux Remote, the one signed process that holds the macOS grants
/// for Computer Use and Screen Sharing (docs/cmux-remote.md).
/// The cmux-tui daemon runs cmux Remote whenever this build embeds it: Computer Use (the
/// Upstream driver) runs in it, and it serves this Mac's Screen Sharing, so a grant needs no
/// relaunch. A build without it uses the app's own helper and host.
/// - `endSharingOnQuit` (off by default): a Screen Sharing session ends when cmux quits. Off,
///   cmux Remote keeps this Mac available to the person's devices while cmux is quit.
/// - `shareWithOwnDevicesByDefault` (on by default; an explicit off still wins): sent with this Mac's device hub registration
///   (`shareWithOwnDevices`); on, the account's other devices view this Mac while its sharing switch was
///   never set, with no Allow. The acpmux daemon reads it from the file itself when it registers.
/// - `ultra` (Auto by default): Ultra Connection Mode, Off, Auto or Always. The Rust tunnel starts
///   read it from the file themselves (cmux-tui-util `user_settings::ultra`); kept here so the row
///   reads back. Without it, the retired toggle `ultraMode` set to true reads as Always, as Rust does.
/// - `screenSharingProfile` (Balanced by default): what this Mac asks for when it views another
///   Mac. Ultra puts `a=cmux-rd-encode-profile:ultra` in the cmux.rd offer (up to 120 fps and
///   150 Mbps, near-lossless text, on a fast direct link); Balanced sends nothing. Not `ultra`
///   above, which is the WireGuard tunnel's loss repair.
public nonisolated struct RemoteSettings: Sendable, Equatable {
    public var endSharingOnQuit = RemoteSettings.endSharingOnQuitDefault
    public var shareWithOwnDevicesByDefault = RemoteSettings.shareWithOwnDevicesByDefaultDefault
    public var ultra = RemoteSettings.ultraDefault
    public var screenSharingProfile = RemoteSettings.screenSharingProfileDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["remote"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("endSharingOnQuit") { settings.endSharingOnQuit = value }
        if let value = reader.bool("shareWithOwnDevicesByDefault") { settings.shareWithOwnDevicesByDefault = value }
        if let value = reader.choice("ultra", UltraConnectionMode.self) {
            settings.ultra = value
        } else if reader.members["ultra"] == nil, reader.members["ultraMode"]?.boolValue == true {
            settings.ultra = .always
        }
        if let value = reader.choice("screenSharingProfile", ScreenSharingProfile.self) {
            settings.screenSharingProfile = value
        }
        diagnostics = reader.diagnostics
        return settings
    }
}
