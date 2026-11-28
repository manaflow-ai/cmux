/// `history.commandRetentionDays` in cmux.json (user decision 2026-10-01):
/// how many days each daemon keeps recorded terminal commands before it
/// deletes them. Whole days, 1 to 3650; 30 when unset. The App sends it with
/// `set-terminal-command-history` to every daemon that serves
/// `terminal-command-history-v1`; the daemon stores it and deletes older
/// commands itself.
extension CmuxConfigSnapshot {
    public static let commandRetentionConfigPath = ["history", "commandRetentionDays"]
    public static let commandRetentionFallback = 30
    /// The daemon's accepted range.
    public static let commandRetentionRange: ClosedRange<Int> = 1...3650

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parseCommandRetention(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Int {
        guard let value = root.value(at: commandRetentionConfigPath) else { return commandRetentionFallback }
        guard let days = value.intValue, commandRetentionRange.contains(days) else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "history.commandRetentionDays",
                                                  message: "expected a whole number of days from 1 to 3650, such as 30"))
            return commandRetentionFallback
        }
        return days
    }

    /// `history.terminalCommands` and `history.commandRetentionDays`.
    mutating func parseTerminalCommandHistory(_ root: JSONValue) {
        let (records, diagnostic) = TerminalCommandHistorySetting.parse(root)
        recordsTerminalCommands = records
        if let diagnostic { diagnostics.append(diagnostic) }
        commandRetentionDays = Self.parseCommandRetention(root, diagnostics: &diagnostics)
    }
}
