public import CmuxNextDesign

/// `layout.stripScrollbar` in cmux.json: "auto" (default), "always" or
/// "off"; `true` means "auto" and `false` "off"
/// (plans/cmux-next/dock-column.md, B4).
public nonisolated enum StripScrollbarSetting {
    public static let configPath = ["layout", "stripScrollbar"]
    public static let fallback: StripScrollbarMode = .auto

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (StripScrollbarMode, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        if let flag = value.boolValue { return (flag ? .auto : .off, nil) }
        guard let text = value.stringValue, let mode = StripScrollbarMode(configValue: text) else {
            let choices = StripScrollbarMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "layout.stripScrollbar", message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}
