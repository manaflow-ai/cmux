import CoreGraphics
public import CmuxNextDesign

/// `appearance.statusIndicator.*`: how loading and status indicators look
/// on sidebar rows, tabs, sections and pane headers.
enum StatusIndicatorConfigParser {
    static let path = ["appearance", "statusIndicator"]

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> StatusIndicatorSettings {
        var settings = StatusIndicatorSettings()
        guard var reader = ConfigFieldReader(root, at: path, diagnostics: &diagnostics) else { return settings }
        if let value = reader.choice("style", StatusIndicatorStyle.self) { settings.style = value }
        if let value = reader.number("size", range: Double(StatusIndicatorSettings.scaleRange.lowerBound)...Double(StatusIndicatorSettings.scaleRange.upperBound)) {
            settings.scale = CGFloat(value)
        }
        if let value = reader.points("thickness", range: StatusIndicatorSettings.thicknessRange) { settings.thickness = value }
        if let value = reader.color("color") { settings.color = value }
        diagnostics += reader.diagnostics
        return settings
    }
}
