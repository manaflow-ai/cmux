public import CmuxNextDesign

/// `focusRing.*` and `notifications.attention.*` in cmux.json. A bad value
/// keeps its default with a diagnostic.
enum PaneRingConfigParser {
    static func focusRing(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> FocusRingSettings {
        var settings = FocusRingSettings()
        guard var reader = ConfigFieldReader(root, at: ["focusRing"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        if let value = reader.choice("style", FocusRingStyle.self) { settings.style = value }
        if let value = reader.choice("contrast", FocusRingContrast.self) { settings.contrast = value }
        if let value = reader.color("color") { settings.color = value }
        if let value = reader.points("width", range: FocusRingSettings.widthRange) { settings.width = value }
        if let value = reader.members["cornerRadius"], value.stringValue == "pane" || { if case .null = value { true } else { false } }() {
            settings.cornerRadius = nil
        } else if let value = reader.points("cornerRadius", range: FocusRingSettings.cornerRadiusRange) {
            settings.cornerRadius = value
        }
        if let value = reader.bool("showWhenSinglePane") { settings.showsForSinglePane = value }
        diagnostics += reader.diagnostics
        return settings
    }

    static func attention(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> AttentionSettings {
        var settings = AttentionSettings()
        guard var reader = ConfigFieldReader(root, at: ["notifications", "attention"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.choice("style", AttentionStyle.self) { settings.style = value }
        if let value = reader.color("color") { settings.color = value }
        if let value = reader.points("width", range: AttentionSettings.widthRange) { settings.width = value }
        let blinks = AttentionSettings.blinkRange
        if let value = reader.number("blinkCount", range: Double(blinks.lowerBound)...Double(blinks.upperBound)) {
            settings.blinkCount = Int(value.rounded())
        }
        if let value = reader.number("duration", range: AttentionSettings.durationRange) { settings.duration = value }
        if let value = reader.bool("persist") { settings.persists = value }
        if let value = reader.bool("showOnTab") { settings.showsOnTab = value }
        if let value = reader.bool("showOnSidebar") { settings.showsOnSidebar = value }
        diagnostics += reader.diagnostics
        return settings
    }
}
