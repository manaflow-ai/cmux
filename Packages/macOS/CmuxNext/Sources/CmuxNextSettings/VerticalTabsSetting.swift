/// Vertical tabs in cmux.json (Leo 2026-10-20: "a per-workspace Vertical tabs option, off by default,
/// and a Use vertical tabs for all workspaces control"):
/// - `tabs.verticalTabs`: every workspace shows its tabs as a vertical list beside its panes, unless the
///   workspace turned them off itself. Off by default: tabs stay a horizontal strip.
/// - `tabs.verticalTabsExpandOnHover`: a collapsed list (icons only) widens to show titles while the
///   pointer is over it, as Chrome's and Edge's do. On by default.
/// The tab list's empty-area menu (Use Vertical Tabs for All Workspaces, Auto-Expand Tabs on Hover),
/// the palette and Settings write them.
public nonisolated struct VerticalTabsSetting: Sendable {
    public static let configPath = ["tabs", "verticalTabs"]
    public static let fallback = false
    public static let expandOnHoverPath = ["tabs", "verticalTabsExpandOnHover"]
    public static let expandOnHoverFallback = true

    public init() {}

    /// A missing key is the default with no diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        parseToggle(root, path: configPath, fallback: fallback)
    }

    static func parseExpandOnHover(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        parseToggle(root, path: expandOnHoverPath, fallback: expandOnHoverFallback)
    }

    private static func parseToggle(_ root: JSONValue, path: [String], fallback: Bool) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: path) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
