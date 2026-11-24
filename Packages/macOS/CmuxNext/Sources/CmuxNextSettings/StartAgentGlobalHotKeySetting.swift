/// `app.startAgentGlobalHotKey`: whether Start Agent from Any App
/// (⌃⌥⌘Space by default, its own row in Keyboard Shortcuts) is a
/// system-wide hot key. On when unset or invalid, unlike `app.globalHotKey`:
/// off by default a new user never found it, which a report rated a reason to
/// quit (Leo, 2026-11-08, ask-a862e90c70: "those NEED to be written down and
/// FIXED"). Turning it off gives the key back to every other app.
nonisolated extension CmuxConfigSnapshot {
    /// `app.startAgentGlobalHotKey`.
    public var startAgentGlobalHotKey: Bool {
        root.value(at: Self.startAgentGlobalHotKeyPath)?.boolValue ?? Self.startAgentGlobalHotKeyDefault
    }

    /// A diagnostic when `app.startAgentGlobalHotKey` is set to something other than a bool.
    static func startAgentGlobalHotKeyDiagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        guard let value = root.value(at: startAgentGlobalHotKeyPath), value.boolValue == nil else { return [] }
        return [SettingsDiagnostic(kind: .invalidValue, path: startAgentGlobalHotKeyPath.joined(separator: "."),
                                   message: "expected true or false")]
    }
}
