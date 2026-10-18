public import CmuxNextDesign

/// `appearance.backgroundVideo`, `appearance.backgroundVideoOnBattery` and
/// `appearance.backgroundAvoidPanes` (backgrounds plan phase 5).
enum BackdropPlaybackConfigParser {
    static let path = ["appearance"]

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> BackdropPlaybackSettings {
        var settings = BackdropPlaybackSettings()
        guard var reader = ConfigFieldReader(root, at: path, diagnostics: &diagnostics) else { return settings }
        if let value = reader.choice("backgroundVideo", BackdropVideoMode.self) { settings.video = value }
        if let value = reader.choice("backgroundVideoOnBattery", BackdropBatteryMode.self) { settings.onBattery = value }
        if let value = reader.bool("backgroundAvoidPanes") { settings.avoidsPanes = value }
        diagnostics += reader.diagnostics
        return settings
    }
}
