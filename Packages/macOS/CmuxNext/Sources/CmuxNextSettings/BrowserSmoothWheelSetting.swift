/// `browser.smoothWheelScroll` in cmux.json: a mouse wheel scrolls web views
/// (WebKit browser tabs, Markdown, Monaco and the other pages) with Chrome-style
/// animation instead of one jump per notch. On by default; Reduce Motion turns
/// it off whatever this says. A trackpad is never touched.
public nonisolated struct BrowserSmoothWheelSetting: Sendable {
    public let configPath = ["browser", "smoothWheelScroll"]
    public let fallback = true

    public init() {}

    /// Absent is on; a value that is not a bool is on plus a diagnostic.
    func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "browser.smoothWheelScroll", message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
