/// `terminal.predictiveEcho` in cmux.json: whether a terminal shows the characters
/// typed into it before the host echoes them, as mosh does. `off` (the default) makes no prediction
/// engine at all; `remote` predicts for remote terminals and whenever the measured echo is slow;
/// `always` predicts in every terminal once an echo confirmed it. A bad value is `off` plus a
/// diagnostic.
public nonisolated enum TerminalPredictiveEchoSetting: String, Sendable, CaseIterable {
    case off
    case remote
    case always

    public static let path = ["terminal", "predictiveEcho"]
    public static let fallback = TerminalPredictiveEchoSetting.off

    /// A missing key is the default with no diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (TerminalPredictiveEchoSetting, SettingsDiagnostic?) {
        guard let value = root.value(at: path) else { return (fallback, nil) }
        guard let text = value.stringValue, let setting = TerminalPredictiveEchoSetting(rawValue: text) else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."),
                                                 message: "expected \"off\", \"remote\" or \"always\""))
        }
        return (setting, nil)
    }
}
