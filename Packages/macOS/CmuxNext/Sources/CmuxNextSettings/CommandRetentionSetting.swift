/// `history.commandRetentionDays` in cmux.json (user decision 2026-10-01):
/// how many days each daemon keeps recorded terminal commands before it
/// deletes them. Whole days, 1 to 3650; 30 when unset. The App sends it with
/// `set-terminal-command-history` to every daemon that serves
/// `terminal-command-history-v1`; the daemon stores it and deletes older
/// commands itself.
public nonisolated enum CommandRetentionSetting {
    public static let configPath = ["history", "commandRetentionDays"]
    public static let fallback = 30
    /// The daemon's accepted range.
    public static let range: ClosedRange<Int> = 1...3650

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Int {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let days = value.intValue, range.contains(days) else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "history.commandRetentionDays",
                                                  message: "expected a whole number of days from 1 to 3650, such as 30"))
            return fallback
        }
        return days
    }
}
