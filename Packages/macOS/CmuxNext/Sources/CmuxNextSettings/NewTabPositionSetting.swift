/// `tabs.newTabPosition` in cmux.json: "afterCurrent" (default), "end" or "start".
nonisolated extension NewTabPosition {
    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (NewTabPosition, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let position = NewTabPosition(rawValue: text) else {
            let choices = NewTabPosition.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "tabs.newTabPosition", message: "expected one of \(choices)"))
        }
        return (position, nil)
    }
}

extension CmuxConfigSnapshot {
    /// `tabs.newTabPosition`; "afterCurrent" when unset or invalid (the diagnostic is in `diagnostics`).
    public var newTabPosition: NewTabPosition { NewTabPosition.parse(root).0 }
}
