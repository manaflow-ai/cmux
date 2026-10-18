public import CmuxNextDesign

/// `appearance.glassLegibility` in cmux.json: "primary" (default) or "all", the text the window's
/// glass keeps readable over background art (``ArtLegibility``).
public nonisolated enum GlassLegibilitySetting {
    public static let configPath = ["appearance", "glassLegibility"]
    public static let fallback: ArtLegibility = .primary

    /// A missing key is the default with no diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (ArtLegibility, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let legibility = ArtLegibility(rawValue: text) else {
            let choices = ArtLegibility.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "appearance.glassLegibility",
                                                 message: "expected one of \(choices)"))
        }
        return (legibility, nil)
    }
}
