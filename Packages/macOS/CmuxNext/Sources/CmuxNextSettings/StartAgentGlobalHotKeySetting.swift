/// `app.startAgentGlobalHotKey`: whether Start Agent from Any App
/// (⌃⌥⌘Space by default, its own row in Keyboard Shortcuts) is a
/// system-wide hot key. On when unset or invalid, so a new person can discover
/// the key from any app. The setting still lets them release the key.
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
