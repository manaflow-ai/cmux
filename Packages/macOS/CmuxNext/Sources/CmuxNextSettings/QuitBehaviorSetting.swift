/// What Quit does with the local terminals, which run in cmux-tui and
/// outlive the app (user decision 2026-09-30).
public nonisolated enum QuitBehavior: String, Sendable, Hashable, CaseIterable {
    /// Show the quit sheet when local terminals exist.
    case ask
    /// Quit and leave the terminals running.
    case keep
    /// Quit and end every local terminal and the local cmux-tui daemon.
    case end
}

/// `app.quitBehavior` in cmux.json: "ask" (default), "keep" or "end". The
/// quit sheet's "Don't ask again" writes "keep" or "end".
public nonisolated enum QuitBehaviorSetting {
    public static let configPath = ["app", "quitBehavior"]
    public static let fallback: QuitBehavior = .ask

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (QuitBehavior, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let behavior = QuitBehavior(rawValue: text) else {
            let choices = QuitBehavior.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "app.quitBehavior", message: "expected one of \(choices)"))
        }
        return (behavior, nil)
    }
}
