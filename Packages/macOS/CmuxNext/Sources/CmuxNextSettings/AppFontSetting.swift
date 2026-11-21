/// `appearance.font` in cmux-next.json: the family the whole app draws in, chrome and pages
/// (`DesignSettings.appFontFamily`). "system" (default) is the macOS system font; the other
/// values are families every Mac ships (`values`, from schemas/settings/source/appearance.json).
public nonisolated struct AppFontSetting {
    public nonisolated init() {}

    /// The family to draw in, nil for the system font. A missing key is the system font with no
    /// diagnostic; a value not listed is the system font plus a diagnostic.
    static func parse(_ root: JSONValue) -> (String?, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (nil, nil) }
        guard let text = value.stringValue, values.contains(text) else {
            let choices = values.map { "\"\($0)\"" }.joined(separator: ", ")
            return (nil, SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."), message: "expected one of \(choices)"))
        }
        return (text == fallback ? nil : text, nil)
    }
}
