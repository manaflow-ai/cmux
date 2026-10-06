/// `browser.showBookmarksBar` in cmux.json: the bookmarks bar under every
/// browser toolbar (plans/cmux-next/bookmarks.md). Off by default.
public nonisolated enum BookmarksBarSetting {
    public static let configPath = ["browser", "showBookmarksBar"]

    /// Absent is off; a value that is not a bool is off plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (false, nil) }
        guard let shown = value.boolValue else {
            return (false, SettingsDiagnostic(kind: .invalidValue, path: "browser.showBookmarksBar", message: "expected true or false"))
        }
        return (shown, nil)
    }
}
