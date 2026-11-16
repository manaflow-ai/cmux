public import CmuxNextDesign

/// `appearance.fontSmoothing` in cmux.json: `auto` (the default), `antialiased` or `subpixel`
/// (``FontSmoothing``), for native and web text.
///
/// Web pages follow a change at once (``WebTheme``). Native text follows it at the next launch:
/// AppKit fixes its text weight at its first draw (``ProcessFontSmoothing``).
public nonisolated struct FontSmoothingSetting {
    public nonisolated init() {}
    // The path and default are generated from schemas/settings/source/appearance.json.

    /// A missing key is ``fallback`` with no diagnostic; a bad value is ``fallback`` plus a diagnostic.
    static func parse(_ root: JSONValue) -> (FontSmoothing, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        // The first release's name for auto.
        if value.stringValue == "system" { return (.auto, nil) }
        guard let text = value.stringValue, let mode = FontSmoothing(rawValue: text) else {
            let choices = FontSmoothing.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                 message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}
