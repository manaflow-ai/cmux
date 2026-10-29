public import CmuxNextAppearance

/// The optional public-domain painting in `appearance.backdropArt`.
public struct BackdropArtSetting: Sendable {
    /// The shared Settings, CLI and cmux.json path.
    public let configPath = ["appearance", "backdropArt"]

    /// Creates the setting's parser and schema path.
    public init() {}

    /// Missing, `none` or a removed work disables art; invalid values produce a diagnostic.
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> BackdropArt? {
        guard let value = root.value(at: configPath) else { return nil }
        if value.stringValue == "none" { return nil }
        if let name = value.stringValue, BackdropArt.removedIDs.contains(name) { return nil }
        if let name = value.stringValue, let art = BackdropArt(id: name) { return art }
        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.backdropArt",
                                              message: "expected none or a bundled public-domain painting"))
        return nil
    }
}
