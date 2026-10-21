/// `tabs.terminalFirst` in cmux.json (#23021): off by default, so a person's
/// Cmd-T opens the New Tab page and a split from a browser tab, the page or an
/// agent chat opens the page too (cx-hvc57, cx-jfo7). On, Cmd-T, Cmd-D and
/// Cmd-Shift-D open a terminal, as in cmux classic. Scripts (CLI, MCP) are not
/// affected: they already get a tab of the pane's kind.
public nonisolated enum TerminalFirstSetting {
}

nonisolated extension TerminalFirstSetting {
    public static let configPath = ["tabs", "terminalFirst"]
    public static let fallback = false

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "tabs.terminalFirst",
                                                   message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
