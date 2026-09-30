/// `layout.defaultColumnWidth` in cmux.json: the width of a new column as a
/// proportion of the viewport, 0.1 to 1.0; 0.5 when unset (niri
/// `default-column-width { proportion 0.5; }`, plans/cmux-next/niri.md).
/// niri also takes `fixed <px>`; cmux does not, because the daemon stores
/// column widths as viewport fractions, so a fixed width would change on
/// every window resize.
public nonisolated enum DefaultColumnWidthSetting {
    public static let configPath = ["layout", "defaultColumnWidth"]
    public static let fallback = 0.5
    /// The daemon's column width range (`set-viewport-pane-width`).
    public static let range: ClosedRange<Double> = 0.1...1.0

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Double {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let number = value.doubleValue, range.contains(number) else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "layout.defaultColumnWidth",
                                                  message: "expected a proportion of the window width from 0.1 to 1.0, such as 0.5"))
            return fallback
        }
        return number
    }
}
