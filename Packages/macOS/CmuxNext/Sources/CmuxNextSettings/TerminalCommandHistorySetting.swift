/// `history.terminalCommands` in cmux.json (plans/cmux-next/history.md 3,
/// user decision 2026-09-30): record finished shell commands (OSC 133) in
/// each machine's session journal for the history page. Default `false`:
/// a command line can hold secrets, so history of commands is opt-in. The
/// App turns it on or off on every connected daemon that serves
/// `terminal-command-journal-v1`; a daemon records nothing until told.
public nonisolated enum TerminalCommandHistorySetting {
    public static let configPath = ["history", "terminalCommands"]
    public static let fallback = false

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard case .bool(let enabled) = value else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "history.terminalCommands", message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
