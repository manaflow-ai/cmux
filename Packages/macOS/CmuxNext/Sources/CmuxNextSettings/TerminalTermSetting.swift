/// `terminal.term` in cmux.json: the `TERM` every new local terminal starts
/// with (``TerminalTerm``). Default `xterm-256color` (user decision
/// 2026-11-05: `ssh host htop` failed with "cannot initialize terminal type
/// xterm-ghostty" on hosts without Ghostty's terminfo). `xterm-ghostty` is
/// the opt-in, applied only when its entry is installed on this Mac.
/// `configPath` and `fallback` are generated from schemas/settings/source/terminal.json.
public nonisolated struct TerminalTermSetting {
    public nonisolated init() {}

    /// A missing key is the default with no diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (TerminalTerm, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let term = TerminalTerm(rawValue: text) else {
            let choices = TerminalTerm.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "terminal.term", message: "expected one of \(choices)"))
        }
        return (term, nil)
    }
}
