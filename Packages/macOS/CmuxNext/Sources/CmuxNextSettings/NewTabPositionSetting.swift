/// Where Cmd-T and the strip's + put a new tab (cx-d0d.58). Chrome and Edge append it, and so does
/// cmux by default; the tab menu's New Tab to the Right always puts it right after that tab.
public nonisolated enum NewTabPosition: String, Sendable, Hashable, CaseIterable {
    /// At the end of the pane's tabs.
    case end
    /// Right after the selected tab.
    case afterCurrent
}

/// `tabs.newTabPosition` in cmux.json: "end" (default) or "afterCurrent".
nonisolated extension NewTabPosition {
    public static let configPath = ["tabs", "newTabPosition"]
    public static let fallback: NewTabPosition = .end

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
    /// `tabs.newTabPosition`; "end" when unset or invalid (the diagnostic is in `diagnostics`).
    public var newTabPosition: NewTabPosition { NewTabPosition.parse(root).0 }
}
