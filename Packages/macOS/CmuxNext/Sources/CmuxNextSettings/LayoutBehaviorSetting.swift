public import CmuxNextDesign

/// `layout.centerFocusedColumn` in cmux.json: "never" (default), "always" or
/// "on-overflow" (niri `center-focused-column`, plans/cmux-next/niri.md).
public nonisolated enum CenterFocusedColumnSetting {
    public static let configPath = ["layout", "centerFocusedColumn"]
    public static let fallback: CenterFocusedColumn = .never

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (CenterFocusedColumn, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let mode = CenterFocusedColumn(configValue: text) else {
            let choices = CenterFocusedColumn.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "layout.centerFocusedColumn", message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}
