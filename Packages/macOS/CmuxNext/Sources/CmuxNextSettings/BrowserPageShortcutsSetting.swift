/// `browser.pageShortcuts` in cmux.json: who gets a shortcut that cmux and a
/// web page both use (CMUX-641: Linear's Cmd-K opened cmux Search Chats).
/// `ask` (the default) and `page` give the page the key first and run the
/// cmux action only when the page leaves it unhandled; `ask` also asks, at
/// the first key a page takes, which should win. `cmux` runs the cmux action
/// and the page never sees the key. App and window keys stay with cmux in
/// every mode. `configPath`, `fallback` and the enum come from
/// schemas/settings/source/browser.json (SettingsSchema+Browser*.generated.swift).
public nonisolated struct BrowserPageShortcutsSetting: Sendable {
    /// Creates the `browser.pageShortcuts` parser.
    public init() {}

    /// Absent is `ask`; a value that is no choice is `ask` plus a diagnostic.
    func parse(_ root: JSONValue) -> (BrowserPageShortcuts, SettingsDiagnostic?) {
        guard let value = root.value(at: Self.configPath) else { return (Self.fallback, nil) }
        guard let mode = value.stringValue.flatMap(BrowserPageShortcuts.init(rawValue:)) else {
            let expected = BrowserPageShortcuts.allCases.map(\.rawValue).joined(separator: ", ")
            return (Self.fallback, SettingsDiagnostic(kind: .invalidValue, path: "browser.pageShortcuts", message: "expected one of \(expected)"))
        }
        return (mode, nil)
    }
}
