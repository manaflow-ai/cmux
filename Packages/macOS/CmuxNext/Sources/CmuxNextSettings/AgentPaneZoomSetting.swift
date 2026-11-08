import Foundation

/// The agent chat's per-surface display zoom. It is intentionally separate from
/// `app.uiScale`, which scales cmux chrome and first-party pages together, and from
/// `home.chiefZoom` (``HomeChiefZoomSetting``), the Chief chat's own zoom (issue 38169).
public struct AgentPaneZoomSetting: Sendable {
    public init() {}
    public static let configPath = ["agentPane", "zoom"]
    public static let fallback = 1.0
    public static let range: ClosedRange<Double> = 0.5...2.0
    public static let step = 0.1

    public static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Double {
        parseChatZoom(root, path: configPath, range: range, fallback: fallback, diagnostics: &diagnostics)
    }
}

/// `home.chiefZoom`: the Chief chat's display zoom (Chief: Zoom In / Zoom Out / Actual Size, Cmd-= / Cmd-- /
/// Cmd-0 on Home). Its own setting, so zooming the Chief chat never resizes an agent chat and the reverse
/// (issue 38169). 1 is the Chief chat at the agent chat's default text size (`HomeNativeTranscriptView`).
public struct HomeChiefZoomSetting: Sendable {
    public init() {}
    public static let configPath = ["home", "chiefZoom"]
    public static let fallback = 1.0
    public static let range: ClosedRange<Double> = 0.5...2.0
    public static let step = 0.1

    public static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Double {
        parseChatZoom(root, path: configPath, range: range, fallback: fallback, diagnostics: &diagnostics)
    }
}

/// A chat zoom at `path`: the fallback when unset or not a number, clamped to `range` (with a diagnostic).
private func parseChatZoom(_ root: JSONValue, path: [String], range: ClosedRange<Double>, fallback: Double,
                           diagnostics: inout [SettingsDiagnostic]) -> Double {
    let key = path.joined(separator: ".")
    guard let value = root.value(at: path) else { return fallback }
    guard let number = value.doubleValue, number.isFinite else {
        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: key,
                                              message: "expected a number from \(range.lowerBound) to \(range.upperBound)"))
        return fallback
    }
    if !range.contains(number) {
        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: key,
                                              message: "expected a zoom from \(range.lowerBound) to \(range.upperBound); clamped"))
    }
    return min(max(number, range.lowerBound), range.upperBound)
}
