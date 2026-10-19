/// `browser.showAgentCursor` in cmux.json: when an agent drives a browser
/// tab, its cursor, click ripple and keystroke caption show on the page
/// (plans/cmux-next/agent-cursor.md). On by default; off, nothing of an
/// agent's input is drawn. A person's own input never shows a cursor.
public nonisolated struct AgentCursorSetting: Sendable {
    /// The key's path in cmux.json.
    public let configPath = ["browser", "showAgentCursor"]
    /// The value when the key is absent: shown.
    public let fallback = true

    /// The setting's path and default.
    public init() {}

    /// Absent is on; a value that is not a bool is on plus a diagnostic.
    func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let shown = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "browser.showAgentCursor", message: "expected true or false"))
        }
        return (shown, nil)
    }
}
