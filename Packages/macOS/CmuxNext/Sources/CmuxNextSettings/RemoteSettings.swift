/// `remote.*` in cmux.json: Screen Sharing (docs/cmux-helper.md).
/// - `endSharingOnQuit` (off by default): a Screen Sharing session ends when cmux quits. Read
///   by nothing since the old remote host's supervisor left (it was its `headless` switch); kept so the
///   setting and its managed key stay until it is wired to cmux Helper or retired.
/// - `ultra` (Auto by default): Ultra Connection Mode, Off, Auto or Always. The Rust tunnel starts
///   read it from the file themselves (cmux-tui-util `user_settings::ultra`); kept here so the row
///   reads back. Without it, the retired toggle `ultraMode` set to true reads as Always, as Rust does.
public nonisolated struct RemoteSettings: Sendable, Equatable {
    public var endSharingOnQuit = RemoteSettings.endSharingOnQuitDefault
    public var ultra = RemoteSettings.ultraDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["remote"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("endSharingOnQuit") { settings.endSharingOnQuit = value }
        if let value = reader.choice("ultra", UltraConnectionMode.self) {
            settings.ultra = value
        } else if reader.members["ultra"] == nil, reader.members["ultraMode"]?.boolValue == true {
            settings.ultra = .always
        }
        diagnostics = reader.diagnostics
        return settings
    }
}
