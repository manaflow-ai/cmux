// The path and default are generated from schemas/settings/source/home.json
// (Schema/SettingsSchema+Home.generated.swift).

/// `home.attachments.keepLocation` in cmux.json: whether photos and videos
/// the Home composer attaches keep their location metadata (photo GPS, a
/// video's ISO 6709 location). Off by default: the data side strips it
/// before hashing (`HomeStore.prepareAttachment(keepLocation:)`).
public nonisolated struct HomeKeepLocationSetting {
    public nonisolated init() {}

    /// Absent is off; a value that is not a bool is off plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let keep = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "home.attachments.keepLocation", message: "expected true or false"))
        }
        return (keep, nil)
    }
}
