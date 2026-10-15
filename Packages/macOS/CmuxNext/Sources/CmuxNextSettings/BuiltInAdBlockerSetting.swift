/// `browser.builtInAdBlocker` in cmux.json: the full uBlock Origin (Manifest
/// V2, GPL-3.0) that ships inside cmux loads into Chromium tabs. On by
/// default; off, Chromium starts without it the next time it starts (the
/// extension and its settings stay in the profile).
public nonisolated struct BuiltInAdBlockerSetting {
    public nonisolated init() {}
    public static let configPath = ["browser", "builtInAdBlocker"]
    public static let fallback = true

    /// Absent is on; a value that is not a bool is on plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "browser.builtInAdBlocker", message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
