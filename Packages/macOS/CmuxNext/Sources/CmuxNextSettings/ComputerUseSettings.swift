/// `computerUse.*` in cmux.json. `enabled` (off by default) lets cmux start
/// the Developer ID signed cmux Computer Use helper, so agents can see and
/// use other apps. Off, no helper starts and macOS asks for nothing.
/// `driver` ("upstream" by default) picks the helper: "upstream" runs the
/// helper v2 engine in cmux Remote (docs/cmux-remote.md), or the app's own helper v2
/// without it; a build with neither runs the legacy helper. "legacy" keeps the
/// cmux-cua 0.8.12 helper.
/// `livePreview` (on by default) shows a small live view of the app an agent
/// drives at the top right of that agent's chat.
public nonisolated struct ComputerUseSettings: Sendable, Equatable {
    public var enabled = ComputerUseSettings.enabledDefault
    public var driver = ComputerUseSettings.driverDefault
    /// Whether cmux.json names the driver (the person chose it), not the default.
    public var driverIsSet = false
    public var livePreview = ComputerUseSettings.livePreviewDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["computerUse"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        if let value = reader.choice("driver", ComputerUseDriver.self) {
            settings.driver = value
            settings.driverIsSet = true
        }
        if let value = reader.bool("livePreview") { settings.livePreview = value }
        diagnostics = reader.diagnostics
        return settings
    }
}
