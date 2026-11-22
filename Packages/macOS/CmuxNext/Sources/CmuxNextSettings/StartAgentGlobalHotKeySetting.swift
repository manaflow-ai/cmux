/// `app.startAgentGlobalHotKey`: whether Start Agent from Any App
/// (⌃⌥⌘Space by default, its own row in Keyboard Shortcuts) is a
/// system-wide hot key. Off when unset or invalid (cx-hkat), like
/// `app.globalHotKey`: a system-wide key is taken from every other app only
/// when the user asks for it.
nonisolated extension CmuxConfigSnapshot {
    public static let startAgentGlobalHotKeyPath = ["app", "startAgentGlobalHotKey"]
    /// Off when unset or invalid.
    public static let startAgentGlobalHotKeyFallback = false

    /// `app.startAgentGlobalHotKey`.
    public var startAgentGlobalHotKey: Bool {
        root.value(at: Self.startAgentGlobalHotKeyPath)?.boolValue ?? Self.startAgentGlobalHotKeyFallback
    }

    /// A diagnostic when `app.startAgentGlobalHotKey` is set to something other than a bool.
    static func startAgentGlobalHotKeyDiagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        guard let value = root.value(at: startAgentGlobalHotKeyPath), value.boolValue == nil else { return [] }
        return [SettingsDiagnostic(kind: .invalidValue, path: startAgentGlobalHotKeyPath.joined(separator: "."),
                                   message: "expected true or false")]
    }
}
