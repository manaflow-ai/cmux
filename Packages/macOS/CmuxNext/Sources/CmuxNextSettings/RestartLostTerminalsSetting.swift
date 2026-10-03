/// `terminal.restartLostTerminals` in cmux.json (user decision 2026-10-02,
/// plans/cmux-next/ownership.md 3.2): when a terminal's host is lost (a
/// crash, a kill, a logout), restart its tab automatically with a new shell
/// in the same directory instead of leaving it dead with a Restart button.
/// Default `false`. The App sends `restart-tab {only_lost}` for each dead
/// tab; the daemon restarts only host losses, never a process that ended on
/// its own.
public nonisolated enum RestartLostTerminalsSetting {
    public static let configPath = ["terminal", "restartLostTerminals"]
    public static let fallback = false

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard case .bool(let enabled) = value else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "terminal.restartLostTerminals",
                                                 message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
