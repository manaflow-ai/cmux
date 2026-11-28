/// `app.globalHotKey`: whether Show/Hide All Windows (⌃⌥⌘.) is a
/// system-wide hot key. Off when unset or invalid (coordinator decision
/// 2026-10-06): a system-wide key is taken from every other app only when the
/// user asks for it. The GPUI app reads the same key.
nonisolated extension CmuxConfigSnapshot {
    public static let globalHotKeyPath = ["app", "globalHotKey"]
    /// Off when unset or invalid.
    public static let globalHotKeyFallback = false

    /// `app.globalHotKey`.
    public var globalHotKey: Bool { root.value(at: Self.globalHotKeyPath)?.boolValue ?? Self.globalHotKeyFallback }

    /// A diagnostic when `app.globalHotKey` is set to something other than a bool.
    static func globalHotKeyDiagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        guard let value = root.value(at: globalHotKeyPath), value.boolValue == nil else { return [] }
        return [SettingsDiagnostic(kind: .invalidValue, path: globalHotKeyPath.joined(separator: "."), message: "expected true or false")]
    }
}
