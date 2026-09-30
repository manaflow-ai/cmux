/// `layout.defaultColumnWidth` in cmux.json (niri `default-column-width`).
public nonisolated enum DefaultColumnWidthSetting {
    public static let configPath = ["layout", "defaultColumnWidth"]
    public static let fallback = 0.5

    // Failing-test stub: parsing lands in the next commit.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Double {
        fallback
    }
}
