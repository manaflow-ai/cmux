/// How the window's Activity indicator shows running long jobs (plans/cmux-next/long-jobs-DESIGN.md).
/// Two designs; Lawrence chose `labeled` as the default (2026-11-03).
public nonisolated enum ActivityIndicatorStyle: String, Sendable, CaseIterable {
    /// A glyph in the top row while jobs run; the job and its progress in its tooltip and popover.
    case icon
    /// The glyph plus the first job's title and percent beside it.
    case labeled
}

/// `ui.activityIndicator` in cmux.json: "labeled" (default) or "icon" (``ActivityIndicatorStyle``).
public nonisolated struct ActivityIndicatorSetting {
    public nonisolated init() {}
    public static let configPath = ["ui", "activityIndicator"]
    public static let fallback: ActivityIndicatorStyle = .labeled

    /// A missing key is the default with no diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (ActivityIndicatorStyle, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let style = ActivityIndicatorStyle(rawValue: text) else {
            let choices = ActivityIndicatorStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                 message: "expected one of \(choices)"))
        }
        return (style, nil)
    }
}
