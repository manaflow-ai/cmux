public import CmuxNextDesign

/// `layout.closeFocus` in cmux.json: "previousNeighbor" (default) or
/// "mostRecent" (plans/cmux-next/close-focus.md, REWRITE.md round 5).
public nonisolated enum CloseFocusSetting {
    public static let configPath = ["layout", "closeFocus"]
    public static let fallback: CloseFocusPolicy = .previousNeighbor

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (CloseFocusPolicy, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let policy = CloseFocusPolicy(configValue: text) else {
            let choices = CloseFocusPolicy.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "layout.closeFocus", message: "expected one of \(choices)"))
        }
        return (policy, nil)
    }
}
