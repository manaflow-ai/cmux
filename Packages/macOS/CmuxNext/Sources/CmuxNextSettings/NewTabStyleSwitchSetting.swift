// NewTabStyleSwitch, the path and the default are generated from schemas/settings/source/labs.json
// (SettingsSchema+Labs*.generated.swift).

/// `labs.newTabStyle` in cmux.json: how the New Tab page shows its style switch. Unset is round
/// dots; a bad value is round dots plus a diagnostic.
nonisolated extension NewTabStyleSwitch {
    static func parse(_ root: JSONValue) -> (NewTabStyleSwitch, SettingsDiagnostic?) {
        let fallback = CmuxConfigSnapshot.newTabStyleDefault
        guard let value = root.value(at: CmuxConfigSnapshot.newTabStylePath) else { return (fallback, nil) }
        guard let text = value.stringValue, let look = NewTabStyleSwitch(rawValue: text) else {
            let choices = NewTabStyleSwitch.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "labs.newTabStyle", message: "expected one of \(choices)"))
        }
        return (look, nil)
    }
}

extension CmuxConfigSnapshot {
    /// `labs.newTabStyle`; round dots when unset or invalid (the diagnostic is in `diagnostics`).
    public var newTabStyle: NewTabStyleSwitch { NewTabStyleSwitch.parse(root).0 }
}
