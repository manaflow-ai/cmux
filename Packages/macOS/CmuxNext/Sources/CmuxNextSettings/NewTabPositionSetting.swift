/// Where Cmd-T (`tabs.newTabPosition`) and the strip's + (`tabs.newTabButtonPosition`) put a new
/// tab (cx-d0d.58). Cmd-T: right after the current tab by default (Lawrence 2026-10-20); the +:
/// at the end, after the last tab, by default (Lucas 2026-11-07). New Tab After Current Tab, New Tab
/// at Start and New Tab at End (and the tab menu's New Tab to the Right) ignore both settings.
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
    /// `tabs.newTabButtonPosition`: the strip's + (and the vertical list's New Tab row).
    public static let buttonConfigPath = ["tabs", "newTabButtonPosition"]
    public static let buttonFallback: NewTabPosition = .end

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (NewTabPosition, SettingsDiagnostic?) {
        parse(root, at: configPath, fallback: fallback)
    }

    /// `tabs.newTabButtonPosition`, read like `tabs.newTabPosition`.
    static func parseButton(_ root: JSONValue) -> (NewTabPosition, SettingsDiagnostic?) {
        parse(root, at: buttonConfigPath, fallback: buttonFallback)
    }

    private static func parse(_ root: JSONValue, at path: [String], fallback: NewTabPosition) -> (NewTabPosition, SettingsDiagnostic?) {
        guard let value = root.value(at: path) else { return (fallback, nil) }
        guard let text = value.stringValue, let position = NewTabPosition(rawValue: text) else {
            let choices = NewTabPosition.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected one of \(choices)"))
        }
        return (position, nil)
    }
}

extension CmuxConfigSnapshot {
    /// `tabs.newTabPosition`; "afterCurrent" when unset or invalid (the diagnostic is in `diagnostics`).
    public var newTabPosition: NewTabPosition { NewTabPosition.parse(root).0 }
    /// `tabs.newTabButtonPosition`; "end" when unset or invalid (the diagnostic is in `diagnostics`).
    public var newTabButtonPosition: NewTabPosition { NewTabPosition.parseButton(root).0 }
}
