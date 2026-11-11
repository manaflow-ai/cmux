/// `browser.showLoadingBar` in cmux-next.json: the thin progress line under a
/// browser tab's address bar while a page loads. Off by default (user,
/// 2026-11-10): the Stop button is the loading cue. `configPath` and `fallback`
/// come from schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated enum BrowserLoadingBarSetting {
    /// Absent is off; a value that is not a bool is off plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let shown = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."), message: "expected true or false"))
        }
        return (shown, nil)
    }
}
