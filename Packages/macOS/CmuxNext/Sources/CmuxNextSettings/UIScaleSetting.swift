import Foundation

/// The `app.uiScale` setting applied to cmux chrome and first-party web pages.
/// Terminal content keeps its own font size.
public struct UIScaleSetting: Sendable {
    /// The cmux.json key path.
    public let configPath: [String]
    /// The default scale, expressed as a multiplier (1 is 100%).
    public let fallback: Double
    /// Supported display scale, from 85% through 150%.
    public let range: ClosedRange<Double>
    /// The increment used by the View menu and keyboard shortcuts.
    public let step: Double

    public init() {
        configPath = ["app", "uiScale"]
        fallback = 1
        range = 0.85...1.5
        step = 0.05
    }

    /// Reads the setting and records a diagnostic for a malformed value.
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Double {
        guard let app = root["app"] else { return fallback }
        guard case .object(let members) = app else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "app", message: "expected an object"))
            return fallback
        }
        guard let value = members["uiScale"] else { return fallback }
        guard let number = value.doubleValue, number.isFinite else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "app.uiScale", message: "expected a number from 0.85 to 1.5"))
            return fallback
        }
        if !range.contains(number) {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "app.uiScale", message: "expected a scale from 0.85 to 1.5; clamped"))
        }
        return number
    }
}
