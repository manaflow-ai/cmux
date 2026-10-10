/// `labs.previewFeatures` in cmux.json: surfaces still being shaped (the
/// agent pane's session coverage label and its Pull requests view). Off by
/// default, so a default app shows only finished surfaces.
extension CmuxConfigSnapshot {
    public static let previewFeaturesPath = ["labs", "previewFeatures"]

    /// Absent is off; a value that is not a bool is off plus a diagnostic.
    static func parsePreviewFeatures(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: previewFeaturesPath) else { return (false, nil) }
        guard let on = value.boolValue else {
            return (false, SettingsDiagnostic(kind: .invalidValue, path: "labs.previewFeatures", message: "expected true or false"))
        }
        return (on, nil)
    }
}

extension CmuxConfigSnapshot {
    /// Stores one setting's parsed value and keeps its diagnostic.
    mutating func take<Value>(_ parsed: (Value, SettingsDiagnostic?), _ keyPath: WritableKeyPath<Self, Value>) {
        self[keyPath: keyPath] = parsed.0
        if let diagnostic = parsed.1 { diagnostics.append(diagnostic) }
    }
}
