/// `browser.import.enabled` in cmux.json: on by default, so cmux offers to bring
/// data over from other browsers as it does today. Off, cmux's Import from
/// Browser entry points leave (the menu items and palette actions, the import
/// tool window, the browser tab's import offer, the import suggestion cards in
/// Settings) and nothing imports by itself: Keep in Sync stops
/// re-reading the other browser's history and a paused card job does not resume.
/// Data already imported stays.
public nonisolated enum BrowserImportSetting {
}

nonisolated extension BrowserImportSetting {
    public static let configPath = ["browser", "import", "enabled"]
    public static let fallback = true

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "browser.import.enabled",
                                                 message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
