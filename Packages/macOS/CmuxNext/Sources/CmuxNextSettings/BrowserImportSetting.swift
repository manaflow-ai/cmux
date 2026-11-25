/// `browser.import.enabled` in cmux.json: on by default, so cmux offers to bring
/// data over from other browsers as it does today. Off, cmux's Import from
/// Browser entry points leave (the menu items and palette actions, the import
/// tool window, the browser tab's import offer, the import suggestion cards in
/// Settings) and nothing imports by itself: Keep in Sync stops
/// re-reading the other browser's history and a paused card job does not resume.
/// Data already imported stays. `configPath` and `fallback` come from
/// schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated enum BrowserImportSetting {
}

nonisolated extension BrowserImportSetting {
    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic (`import.browser_enabled`; only the key crosses).
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        let only = configPath.reversed().reduce(value) { inner, key in .object([key: inner]) }
        let reply = SettingsRust.answer("import.browser_enabled", ["root": only])
        let enabled = reply["enabled"]?.boolValue ?? fallback
        guard let diagnostic = reply["diagnostic"], let message = diagnostic["message"]?.stringValue else { return (enabled, nil) }
        return (enabled, SettingsDiagnostic(kind: .invalidValue, path: diagnostic["path"]?.stringValue ?? "browser.import.enabled",
                                            message: message))
    }
}
