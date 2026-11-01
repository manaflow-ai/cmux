/// `app.touchBar`: whether cmux contributes its action strip to Touch Bar-equipped Macs.
/// Enabled by default; people who prefer the system Control Strip can turn it off in Settings.
nonisolated extension CmuxConfigSnapshot {
    public static let touchBarPath = ["app", "touchBar"]
    public static let touchBarFallback = true

    /// Whether cmux should expose its Touch Bar controls.
    public var touchBar: Bool { root.value(at: Self.touchBarPath)?.boolValue ?? Self.touchBarFallback }

    /// A diagnostic when `app.touchBar` is set to something other than a bool.
    static func touchBarDiagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        guard let value = root.value(at: touchBarPath), value.boolValue == nil else { return [] }
        return [SettingsDiagnostic(kind: .invalidValue, path: touchBarPath.joined(separator: "."), message: "expected true or false")]
    }
}
