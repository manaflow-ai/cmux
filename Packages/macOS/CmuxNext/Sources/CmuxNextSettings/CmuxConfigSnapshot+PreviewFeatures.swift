/// `labs.previewFeatures` in cmux.json: surfaces still being shaped (the
/// agent pane's session coverage label and its Pull requests view). Off by
/// default, so a default app shows only finished surfaces.
/// The path and default are generated from schemas/settings/source/labs.json
/// (SettingsSchema+Labs.generated.swift).
extension CmuxConfigSnapshot {
    /// Absent is off; a value that is not a bool is off plus a diagnostic.
    static func parsePreviewFeatures(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: previewFeaturesPath) else { return (previewFeaturesDefault, nil) }
        guard let on = value.boolValue else {
            return (previewFeaturesDefault, SettingsDiagnostic(kind: .invalidValue, path: "labs.previewFeatures", message: "expected true or false"))
        }
        return (on, nil)
    }

    /// Another Labs toggle (`labs.voiceRoom`): absent is `fallback`; a value that is not a bool
    /// is `fallback` plus a diagnostic.
    static func parseLabsToggle(_ root: JSONValue, path: [String], fallback: Bool) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: path) else { return (fallback, nil) }
        guard let on = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false"))
        }
        return (on, nil)
    }

    /// A Labs text setting (`labs.voiceRoomURL`): absent is `fallback`; a value that is not a
    /// string is `fallback` plus a diagnostic; a string is trimmed.
    static func parseLabsText(_ root: JSONValue, path: [String], fallback: String) -> (String, SettingsDiagnostic?) {
        guard let value = root.value(at: path) else { return (fallback, nil) }
        guard let text = value.stringValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected a string"))
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    /// A Labs number in `range` (`experiments.focusDimAmount`): absent is `fallback`; a value that is
    /// not a number is `fallback` plus a diagnostic; a number outside `range` is clamped into it.
    static func parseLabsFraction(_ root: JSONValue, path: [String], range: ClosedRange<Double>,
                                  fallback: Double) -> (Double, SettingsDiagnostic?) {
        guard let value = root.value(at: path) else { return (fallback, nil) }
        guard let number = value.doubleValue, number.isFinite else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected a number"))
        }
        return (min(max(number, range.lowerBound), range.upperBound), nil)
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
