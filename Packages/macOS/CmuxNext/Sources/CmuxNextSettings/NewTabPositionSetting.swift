/// Where Cmd-T and the strip's + put a new tab (cx-d0d.58). Right after the current tab by
/// default (Lawrence 2026-10-20, was the end as in Chrome); New Tab After Current Tab, New Tab
/// at Start and New Tab at End (and the tab menu's New Tab to the Right) ignore the setting.
public nonisolated enum NewTabPosition: String, Sendable, Hashable, CaseIterable {
    /// Right after the selected tab (after its tab group), the default.
    case afterCurrent
    /// At the end of the pane's tabs.
    case end
    /// First, right after the pinned tabs.
    case start
}

/// `tabs.newTabPosition` in cmux.json: "afterCurrent" (default), "end" or "start".
nonisolated extension NewTabPosition {
    public static let configPath = ["tabs", "newTabPosition"]
    public static let fallback: NewTabPosition = .afterCurrent

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (NewTabPosition, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let position = NewTabPosition(rawValue: text) else {
            let choices = NewTabPosition.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "tabs.newTabPosition", message: "expected one of \(choices)"))
        }
        return (position, nil)
    }
}

extension CmuxConfigSnapshot {
    /// `tabs.newTabPosition`; "afterCurrent" when unset or invalid (the diagnostic is in `diagnostics`).
    public var newTabPosition: NewTabPosition { NewTabPosition.parse(root).0 }
}
