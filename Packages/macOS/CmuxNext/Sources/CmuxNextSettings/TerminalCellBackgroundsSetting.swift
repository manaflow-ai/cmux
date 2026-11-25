public import CmuxNextDesign

/// `appearance.terminalCellBackgrounds` (``TerminalCellBackgrounds``). A missing key is the
/// default; a bad value is the default plus a diagnostic.
public nonisolated struct TerminalCellBackgroundsSetting: Sendable {
    public init() {}

    /// Parses the key.
    ///
    /// - Parameter root: The whole cmux.json value.
    /// - Returns: The mode, and a diagnostic for a value that is not one of the modes.
    public static func parse(_ root: JSONValue) -> (TerminalCellBackgrounds, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let mode = TerminalCellBackgrounds(rawValue: text) else {
            let choices = TerminalCellBackgrounds.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."), message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}
