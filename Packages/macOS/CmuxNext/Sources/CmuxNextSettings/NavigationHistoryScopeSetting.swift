/// `navigation.historyScope` in cmux.json (plans/cmux-next/history.md 4.2a, R69): what Back and
/// Forward walk. `workspace` (default): the current workspace's places in the location trail;
/// `window`: the current window's places across its workspaces; `surface`: the focused surface's
/// own list (a browser page's back and forward). The app maps the value to `HistoryScope`.
public nonisolated struct NavigationHistoryScopeSetting {
    public nonisolated init() {}
    public static let configPath = ["navigation", "historyScope"]
    public static let values = ["workspace", "window", "surface"]
    public static let fallback = "workspace"

    /// A missing key is the default with no diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (String, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, values.contains(text) else {
            let choices = values.map { "\"\($0)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "navigation.historyScope", message: "expected one of \(choices)"))
        }
        return (text, nil)
    }
}
