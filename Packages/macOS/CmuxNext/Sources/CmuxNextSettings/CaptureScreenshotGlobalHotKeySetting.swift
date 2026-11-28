/// `app.captureScreenshotGlobalHotKey`: whether Capture Screenshot to Chat
/// (⌃⌥⌘S by default, its own row in Keyboard Shortcuts) is a system-wide hot
/// key. Off when unset or invalid, like `app.startAgentGlobalHotKey`: a
/// system-wide key is taken from every other app only when the person asks
/// for it. Off, the action still runs from the palette and its key inside cmux.
nonisolated extension CmuxConfigSnapshot {
    /// `app.captureScreenshotGlobalHotKey`.
    public var captureScreenshotGlobalHotKey: Bool {
        root.value(at: Self.captureScreenshotGlobalHotKeyPath)?.boolValue ?? Self.captureScreenshotGlobalHotKeyDefault
    }

    /// A diagnostic when `app.captureScreenshotGlobalHotKey` is set to something other than a bool.
    static func captureScreenshotGlobalHotKeyDiagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        guard let value = root.value(at: captureScreenshotGlobalHotKeyPath), value.boolValue == nil else { return [] }
        return [SettingsDiagnostic(kind: .invalidValue, path: captureScreenshotGlobalHotKeyPath.joined(separator: "."),
                                   message: "expected true or false")]
    }
}
