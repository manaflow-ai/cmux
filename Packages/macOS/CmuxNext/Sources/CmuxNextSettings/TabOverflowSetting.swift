public import CmuxNextDesign

/// `tabs.overflow` in cmux.json: "shrink" (default, Chrome's) or "scroll" (cx-kp9b4). The palette's
/// Tabs: Use Scrolling Tabs and Tabs: Use Shrinking Tabs (`tabs.overflow.scroll`, `tabs.overflow.shrink`)
/// and the strip's one-time hint write it.
public nonisolated enum TabOverflowSetting {
    public static let configPath = ["tabs", "overflow"]
    public static let fallback: TabOverflow = .shrink

    /// A missing key is the default with no diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (TabOverflow, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let mode = TabOverflow(rawValue: text.lowercased()) else {
            let choices = TabOverflow.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "tabs.overflow", message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}
