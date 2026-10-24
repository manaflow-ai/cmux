/// `tabs.terminalFirst` in cmux.json, shown in Settings as cmux Classic Mode (#23021): off by
/// default, so a person's Cmd-T and Cmd-N open the New Tab page and a split from a browser tab, the
/// page or an agent chat opens the page too (cx-hvc57, cx-jfo7). On, every new tab, split,
/// workspace and window a person opens is a terminal, as in cmux classic; New Tab Page (palette, the
/// tab bar's + menu) and New Agent Chat still open the GUI. Scripts (CLI, MCP) are not affected:
/// they already get a tab of the pane's kind and a workspace with a terminal.
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
