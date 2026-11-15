/// `browser.showLoadingBar` in cmux-next.json: the thin progress line under a
/// browser tab's address bar while a page loads. Off by default (user,
/// 2026-11-10): the Stop button is the loading cue. `configPath` and `fallback`
/// come from schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated struct BrowserLoadingBarSetting: Sendable {
    /// Creates the `browser.showLoadingBar` parser.
    public init() {}

    /// Absent is off; a value that is not a bool is off plus a diagnostic.
    func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: Self.configPath) else { return (Self.fallback, nil) }
        guard let shown = value.boolValue else {
            return (Self.fallback, SettingsDiagnostic(kind: .invalidValue, path: Self.configPath.joined(separator: "."), message: "expected true or false"))
        }
        return (shown, nil)
    }
}
