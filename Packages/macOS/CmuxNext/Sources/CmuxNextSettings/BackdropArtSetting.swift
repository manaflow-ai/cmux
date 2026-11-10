public import CmuxNextDesign

/// The optional public-domain painting in `appearance.backdropArt`.
public struct BackdropArtSetting: Sendable {
    /// Creates the setting's parser and schema path.
    public init() {}

    /// The legacy picker's paintings, after None (schemas/settings/source/appearance.json).
    static var artChoices: [SettingChoice] { BackdropArt.allCases.map { SettingChoice($0.rawValue, $0.label) } }

    /// Missing, `none` or a removed work disables art; invalid values produce a diagnostic.
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> BackdropArt? {
        guard let value = root.value(at: Self.configPath) else { return nil }
        if value.stringValue == Self.fallback { return nil }
        if let name = value.stringValue, BackdropArt.removedIDs.contains(name) { return nil }
        if let name = value.stringValue, let art = BackdropArt(id: name) { return art }
        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.backdropArt",
                                              message: "expected none or a bundled public-domain painting"))
        return nil
    }
}
