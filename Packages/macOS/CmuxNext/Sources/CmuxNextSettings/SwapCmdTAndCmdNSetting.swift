/// `tabs.swapCmdTAndCmdN` in cmux.json (cx-xt5k): off by default, so Cmd-T
/// opens a tab in a pane with a tab strip and a workspace from an agent chat
/// or a pane without one, and Cmd-N opens a workspace. On, Cmd-T always opens
/// a workspace in the current group and Cmd-N a tab; both open the New Tab
/// page. A binding the user set for either action wins.
public nonisolated enum SwapCmdTAndCmdNSetting {
}

nonisolated extension SwapCmdTAndCmdNSetting {
    public static let configPath = ["tabs", "swapCmdTAndCmdN"]
    public static let fallback = false

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "tabs.swapCmdTAndCmdN",
                                                   message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
