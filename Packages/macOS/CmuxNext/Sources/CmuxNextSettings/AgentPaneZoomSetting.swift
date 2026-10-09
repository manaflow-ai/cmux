import Foundation

/// The agent chat's per-surface display zoom. It is intentionally separate from
/// `app.uiScale`, which scales cmux chrome and first-party pages together.
public struct AgentPaneZoomSetting: Sendable {
    public static let configPath = ["agentPane", "zoom"]
    public static let fallback = 1.0
    public static let range: ClosedRange<Double> = 0.5...2.0
    public static let step = 0.1

    public static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Double {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let number = value.doubleValue, number.isFinite else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "agentPane.zoom",
                                                  message: "expected a number from 0.5 to 2.0"))
            return fallback
        }
        if !range.contains(number) {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "agentPane.zoom",
                                                  message: "expected a zoom from 0.5 to 2.0; clamped"))
        }
        return min(max(number, range.lowerBound), range.upperBound)
    }
}
