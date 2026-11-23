public import CmuxNextDesign

/// `tabs.shellIconTheme` in cmux.json: "default" (the `>_` glyph) or "machine" (each shell tab draws the icon of
/// the machine it runs on). Paths and the fallback are generated from schemas/settings/source/tabs.json.
public nonisolated struct TabShellIconThemeSetting: Sendable {

    public init() {}

    /// A missing key is the default with no diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (TabShellIconTheme, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let theme = TabShellIconTheme(rawValue: text) else {
            let choices = TabShellIconTheme.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "tabs.shellIconTheme", message: "expected one of \(choices)"))
        }
        return (theme, nil)
    }
}
