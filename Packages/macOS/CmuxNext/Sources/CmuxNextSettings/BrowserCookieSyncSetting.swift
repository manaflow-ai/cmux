/// `browser.import.cookieSync` in cmux.json: whether cookies imported from Chrome (or another
/// Chromium browser) stay in sync after the import. On, a change in that browser's cookie store
/// (and a check at launch) brings the changed sites' cookies over again; it reads only the profile
/// the person imported from, on this Mac, and nothing leaves it. On by default: "Keep in sync" on
/// the Import Cookies card writes the person's answer here, and it does nothing until an import
/// finished. Off stops the watch at once.
///
/// `configPath` and `fallback` come from schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated struct BrowserCookieSyncSetting: Sendable {
    public init() {}

    /// Absent is on; a value that is not a bool is on plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let on = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "browser.import.cookieSync", message: "expected true or false"))
        }
        return (on, nil)
    }
}
