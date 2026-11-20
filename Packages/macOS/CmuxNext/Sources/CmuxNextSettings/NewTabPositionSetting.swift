// NewTabPosition, its paths and defaults are generated from schemas/settings/source/tabs.json
// (SettingsSchema+TabsChoices.generated.swift, SettingsSchema+Tabs.generated.swift).

/// `tabs.newTabPosition` (Cmd-T: "afterCurrent" by default) and `tabs.newTabButtonPosition` (the
/// strip's +: "end" by default) in cmux.json, each "afterCurrent", "end" or "start".
nonisolated extension NewTabPosition {
    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (NewTabPosition, SettingsDiagnostic?) {
        parse(root, at: configPath, fallback: fallback)
    }

    /// `tabs.newTabButtonPosition`, read like `tabs.newTabPosition`.
    static func parseButton(_ root: JSONValue) -> (NewTabPosition, SettingsDiagnostic?) {
        parse(root, at: buttonPath, fallback: buttonDefault)
    }

    private static func parse(_ root: JSONValue, at path: [String], fallback: NewTabPosition) -> (NewTabPosition, SettingsDiagnostic?) {
        guard let value = root.value(at: path) else { return (fallback, nil) }
        guard let text = value.stringValue, let position = NewTabPosition(rawValue: text) else {
            let choices = NewTabPosition.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected one of \(choices)"))
        }
        return (position, nil)
    }
}

extension CmuxConfigSnapshot {
    /// `tabs.newTabPosition`; "afterCurrent" when unset or invalid (the diagnostic is in `diagnostics`).
    public var newTabPosition: NewTabPosition { NewTabPosition.parse(root).0 }
    /// `tabs.newTabButtonPosition`; "end" when unset or invalid (the diagnostic is in `diagnostics`).
    public var newTabButtonPosition: NewTabPosition { NewTabPosition.parseButton(root).0 }
}
