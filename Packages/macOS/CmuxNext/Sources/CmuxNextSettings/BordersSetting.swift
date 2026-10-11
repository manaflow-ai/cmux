public import CmuxNextDesign

/// `appearance.borders` in cmux.json: "default" draws borders, hairlines
/// and separators; "none" removes every one of them (`Borders`).
public nonisolated enum BordersSetting {
    public static let configPath = ["appearance", "borders"]
    public static let fallback: BorderMode = .default

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (BorderMode, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let mode = BorderMode(rawValue: text) else {
            let choices = BorderMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "appearance.borders", message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}
