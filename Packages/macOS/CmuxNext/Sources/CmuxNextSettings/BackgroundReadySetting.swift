/// `app.backgroundReady` (Leo 2026-11-17, ask-b2b0f899c1: "how can we improve those? startup in
/// background maybe?"): `off` (the default) quits as always; `afterQuit` keeps cmux running hidden
/// after Quit so the next open is instant; `afterQuitAndLogin` also starts it hidden at login. What
/// each value means is cmux-background-ready's (Rust, `cmux_background_ready_mode_parse`): this
/// reads the string the person picked, and an unset or unknown value reads as `off`.
public nonisolated struct BackgroundReadySetting {
    public nonisolated init() {}
    /// `app.backgroundReady` in `root`, one of ``values``; a missing or unknown value is ``fallback``.
    public static func value(in root: JSONValue) -> String {
        guard let value = root.value(at: configPath)?.stringValue, values.contains(value) else { return fallback }
        return value
    }

    /// A diagnostic when `app.backgroundReady` is set to something other than one of its values.
    static func diagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        guard let value = root.value(at: configPath), !(value.stringValue.map(values.contains) ?? false) else { return [] }
        return [SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                   message: "expected one of " + values.map { "\"\($0)\"" }.joined(separator: ", "))]
    }
}
