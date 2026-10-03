public import CmuxNextDesign

/// `window.rail` in cmux.json: "leading" (default: the window's leading
/// edge, before the sidebar), "afterSidebar" (between the sidebar and the
/// content column) or "off" (no rail; the sidebar shows its sticky
/// sections).
public nonisolated enum WindowRailSetting {
    public static let configPath = ["window", "rail"]
    public static let fallback: WindowRailPlacement = .leading

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (WindowRailPlacement, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let placement = WindowRailPlacement(rawValue: text) else {
            let choices = WindowRailPlacement.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "window.rail", message: "expected one of \(choices)"))
        }
        return (placement, nil)
    }
}
