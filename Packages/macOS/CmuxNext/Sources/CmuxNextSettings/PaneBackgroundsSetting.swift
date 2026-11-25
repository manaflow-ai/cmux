public import CmuxNextDesign

/// `appearance.paneBackgrounds`: one background behind the whole window (`shared`, the default)
/// or a copy in each pane (`perPane`); plans/cmux-next/pane-backgrounds-DESIGN.md. A missing key
/// is the default; a bad value is the default plus a diagnostic.
public nonisolated struct PaneBackgroundsSetting: Sendable {
    public init() {}

    /// Parses the key.
    ///
    /// - Parameter root: The whole cmux.json value.
    /// - Returns: The mode, and a diagnostic for a value that is not one of the modes.
    public static func parse(_ root: JSONValue) -> (PaneBackgroundMode, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let mode = PaneBackgroundMode(rawValue: text) else {
            let choices = PaneBackgroundMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."), message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}
