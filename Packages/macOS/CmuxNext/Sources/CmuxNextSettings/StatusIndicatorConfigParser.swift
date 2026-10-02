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
        if let value = honoredSources(reader.members["honorStatusStyle"]) {
            settings.honoredStyleSources = value
        } else if reader.members["honorStatusStyle"] != nil {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.statusIndicator.honorStatusStyle",
                                                  message: "expected true, false or a list of sources"))
        }
        diagnostics += reader.diagnostics
        return settings
    }

    /// `true` (every source), `false` (none) or a list of source names.
    static func honoredSources(_ value: JSONValue?) -> Set<StatusReport.Source>? {
        guard let value else { return nil }
        if let bool = value.boolValue { return bool ? Set(StatusReport.Source.allCases) : [] }
        guard let items = value.arrayValue else { return nil }
        var sources = Set<StatusReport.Source>()
        for item in items {
            guard let name = item.stringValue, let source = StatusReport.Source(rawValue: name) else { return nil }
            sources.insert(source)
        }
        return sources
    }

    static let behaviorPath = ["status"]

    /// `status.*`: inferred command busy and run notifications.
    static func behavior(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> StatusBehaviorSettings {
        var settings = StatusBehaviorSettings()
        guard var reader = ConfigFieldReader(root, at: behaviorPath, diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("inferCommandBusy") { settings.inferCommandBusy = value }
        if let value = reader.number("inferCommandBusyAfter", range: StatusBehaviorSettings.inferAfterRange) {
            settings.inferCommandBusyAfter = value
        }
        if let value = reader.number("runNotifyMinimumSeconds", range: StatusBehaviorSettings.runNotifyRange) {
            settings.runNotifyMinimumSeconds = value
        }
        if let value = reader.bool("runNotifyWhenVisible") { settings.runNotifyWhenVisible = value }
        diagnostics += reader.diagnostics
        return settings
    }
}
