public import CmuxNextDesign

/// `ui.calm` in cmux.json: "off" (default), "calm" or "still" (``CalmMode``).
/// It overrides the motion and hover-card settings while on and leaves them
/// as they are, so turning it off restores them.
public nonisolated struct CalmModeSetting {
    public nonisolated init() {}
    public static let configPath = ["ui", "calm"]
    public static let fallback: CalmMode = .off

    /// A missing key is off with no diagnostic; a bad value is off plus a diagnostic.
    static func parse(_ root: JSONValue) -> (CalmMode, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let mode = CalmMode(rawValue: text) else {
            let choices = CalmMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "ui.calm", message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}
