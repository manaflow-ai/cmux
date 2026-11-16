public import CmuxNextDesign

/// `appearance.fontSmoothing` in cmux.json: `antialiased` (the default) draws cmux's native text
/// with thin strokes, as the web UI does; `system` keeps the Mac's own font smoothing.
///
/// The app applies it once per launch, before its first window (``ProcessFontSmoothing``): AppKit
/// fixes its text weight at the first draw, so a change takes effect after cmux restarts.
public nonisolated struct FontSmoothingSetting {
    public nonisolated init() {}
    // The path and default are generated from schemas/settings/source/appearance.json.

    /// A missing key is ``fallback`` with no diagnostic; a bad value is ``fallback`` plus a diagnostic.
    static func parse(_ root: JSONValue) -> (FontSmoothing, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let mode = FontSmoothing(rawValue: text) else {
            let choices = FontSmoothing.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                 message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}
