/// An editor whose settings the code editor can take its defaults from (`editor.importFrom`).
/// The raw value is the setting's choice; ``EditorSettingsSources`` knows where its files are.
public nonisolated enum ImportableEditor: String, Sendable, CaseIterable {
    /// Visual Studio Code: `~/Library/Application Support/Code/User`.
    case vscode
    /// Cursor (VS Code's format): `~/Library/Application Support/Cursor/User`.
    case cursor
    /// Windsurf (VS Code's format): `~/Library/Application Support/Windsurf/User`.
    case windsurf
    /// VSCodium (VS Code's format): `~/Library/Application Support/VSCodium/User`.
    case vscodium
    /// Zed: `~/.config/zed`.
    case zed

    /// The name a person knows it by (a product name: not translated).
    public var name: String {
        switch self {
        case .vscode: "VS Code"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .vscodium: "VSCodium"
        case .zed: "Zed"
        }
    }
}
