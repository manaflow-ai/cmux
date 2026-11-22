public import CmuxNextDesign

/// `appearance.borders` in cmux.json: "default" draws borders, hairlines
/// and separators; "none" removes every one of them (`Borders`).
public nonisolated enum BordersSetting {
    // The path and default are generated from schemas/settings/source/appearance.json.

    /// A missing key is `defaultMode` (the `appearance.chromeStyle` default)
    /// with no diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue, defaultMode: BorderMode = fallback) -> (BorderMode, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (defaultMode, nil) }
        guard let text = value.stringValue, let mode = BorderMode(rawValue: text) else {
            let choices = BorderMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (defaultMode, SettingsDiagnostic(kind: .invalidValue, path: "appearance.borders", message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}
