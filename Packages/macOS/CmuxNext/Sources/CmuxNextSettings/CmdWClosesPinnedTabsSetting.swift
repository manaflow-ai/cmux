/// `tabs.cmdWClosesPinnedTabs` in cmux.json (PINNED-ITEMS-END-TO-END
/// amendment 1): off by default, so the user's Cmd-W on a pinned tab selects
/// the next tab and keeps the pinned one (Chrome parity); on, Cmd-W closes a
/// pinned tab like any other. A tab named by its menu, the CLI or MCP
/// closes either way.
public nonisolated enum CmdWClosesPinnedTabsSetting {
}

nonisolated extension CmdWClosesPinnedTabsSetting {
    public static let configPath = ["tabs", "cmdWClosesPinnedTabs"]
    public static let fallback = false

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "tabs.cmdWClosesPinnedTabs",
                                                   message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
