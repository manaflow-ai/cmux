/// `labs.previewFeatures` in cmux.json: surfaces still being shaped (the App Store, the
/// agent pane's session coverage label and its Pull requests view). Off by
/// default, so a default app shows only finished surfaces.
/// The path and default are generated from schemas/settings/source/labs.json
/// (SettingsSchema+Labs.generated.swift).
extension CmuxConfigSnapshot {
    /// A Labs text setting (`labs.voiceRoomURL`): absent is `fallback`; a value that is not a
    /// string is `fallback` plus a diagnostic; a string is trimmed.
    static func parseLabsText(_ root: JSONValue, path: [String], fallback: String) -> (String, SettingsDiagnostic?) {
        guard let value = root.value(at: path) else { return (fallback, nil) }
        guard let text = value.stringValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected a string"))
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }
}

extension CmuxConfigSnapshot {
    /// Stores one setting's parsed value and keeps its diagnostic.
    mutating func take<Value>(_ parsed: (Value, SettingsDiagnostic?), _ keyPath: WritableKeyPath<Self, Value>) {
        self[keyPath: keyPath] = parsed.0
        if let diagnostic = parsed.1 { diagnostics.append(diagnostic) }
    }

    /// Stores one setting's parsed value and keeps its diagnostics.
    mutating func take<Value>(_ parsed: (Value, [SettingsDiagnostic]), _ keyPath: WritableKeyPath<Self, Value>) {
        self[keyPath: keyPath] = parsed.0
        diagnostics += parsed.1
    }
}
