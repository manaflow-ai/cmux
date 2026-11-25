public import CmuxNextDesign

/// `appearance.selection` in cmux.json: what the selection fill takes (`CmuxTheme.ThemeSelection`).
/// "accent" (the default) tints the selected row and tab with the accent, as before; "neutral" keeps
/// the gray card whatever the accent (a look with a blue accent and the Codex app's gray selected row).
public nonisolated struct SelectionSetting: Sendable {
    public init() {}

    // The path and default are generated from schemas/settings/source/appearance.json.

    /// A missing key is the default with no diagnostic; a bad value is the default plus a diagnostic.
    func parse(_ root: JSONValue) -> (ThemeSelection, SettingsDiagnostic?) {
        guard let value = root.value(at: Self.configPath) else { return (Self.fallback, nil) }
        guard let text = value.stringValue, let selection = ThemeSelection(rawValue: text) else {
            let choices = ThemeSelection.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (Self.fallback, SettingsDiagnostic(kind: .invalidValue, path: "appearance.selection", message: "expected one of \(choices)"))
        }
        return (selection, nil)
    }
}
