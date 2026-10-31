/// `browser.agentSecureStoreFill` in cmux.json (cmux https://github.com/manaflow-ai/cmux/issues/25830):
/// whether an agent may ask the app to fill a sign-in the person saved in the Secure Store into
/// its browser tab (`cmux browser right fill-login`). Off by default; off, every fill answers
/// `disabled`. Saving a sign-in from a Chief card works either way.
public nonisolated struct AgentSecureStoreFillSetting: Sendable {
    /// The key's path in cmux.json.
    public let configPath = ["browser", "agentSecureStoreFill"]
    /// The value when the key is absent: off.
    public let fallback = false

    /// The setting's path and default.
    public init() {}

    /// Absent is off; a value that is not a bool is off plus a diagnostic.
    func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let on = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "browser.agentSecureStoreFill", message: "expected true or false"))
        }
        return (on, nil)
    }
}
