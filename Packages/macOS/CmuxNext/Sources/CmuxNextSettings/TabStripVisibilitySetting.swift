public import CmuxNextDesign

/// `tabs.stripVisibility` in cmux.json: "auto" (default, today's), "always", "whenMultiple" or "never".
/// Rust decides each pane from it (`WindowRules.strip`); its path and default are generated from
/// schemas/settings/source/tabs.json. Settings, the palette's setting row and `cmux settings set` write it.
public nonisolated struct TabStripVisibilitySetting: Sendable {

    public init() {}

    /// A missing key is the default with no diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (TabStripVisibility, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let mode = TabStripVisibility(rawValue: text) else {
            let choices = TabStripVisibility.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "tabs.stripVisibility", message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}
