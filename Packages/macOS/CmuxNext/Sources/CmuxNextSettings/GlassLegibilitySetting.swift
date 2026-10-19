public import CmuxNextDesign

/// `appearance.glassLegibility` in cmux.json: "primary" (default) or "all", the text the window's
/// glass keeps readable over background art (``ArtLegibility``).
public nonisolated struct GlassLegibilitySetting {
    public nonisolated init() {}
    public static let configPath = ["appearance", "glassLegibility"]
    public static let fallback: ArtLegibility = .primary

    /// A missing key is the default with no diagnostic; a bad value is the default plus a diagnostic.
    func parse(_ root: JSONValue) -> (ArtLegibility, SettingsDiagnostic?) {
        guard let value = root.value(at: Self.configPath) else { return (Self.fallback, nil) }
        guard let text = value.stringValue, let legibility = ArtLegibility(rawValue: text) else {
            let choices = ArtLegibility.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (Self.fallback, SettingsDiagnostic(kind: .invalidValue, path: "appearance.glassLegibility",
                                                 message: "expected one of \(choices)"))
        }
        return (legibility, nil)
    }
}
