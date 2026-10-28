/// `browser.builtInAdBlocker` in cmux.json: the full uBlock Origin (Manifest
/// V2, GPL-3.0) that ships inside cmux loads into Chromium tabs. On by
/// default; off, Chromium starts without it the next time it starts (the
/// extension and its settings stay in the profile).
public nonisolated struct BuiltInAdBlockerSetting: Sendable {
    public let configPath = ["browser", "builtInAdBlocker"]
    public let fallback = true

    public init() {}

    /// Absent is on; a value that is not a bool is on plus a diagnostic.
    func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "browser.builtInAdBlocker", message: "expected true or false"))
        }
        return (enabled, nil)
    }

    /// The person set it to `true` (not its default): the built-in ad blocker still loads on a Chromium fork
    /// without the first-tab load.
    func chosen(_ root: JSONValue) -> Bool {
        root.value(at: configPath)?.boolValue == true
    }
}
