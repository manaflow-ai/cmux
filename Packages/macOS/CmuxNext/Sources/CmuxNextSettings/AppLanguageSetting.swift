/// `app.language` in cmux.json: the language cmux's own text is in (Leo, 2026-11-16: "we gotta add
/// settings for changing languages"). `system` (default) follows the macOS language order, as before
/// the setting; any other value is a locale cmux ships. cmux-config's `language` module owns the
/// shipped list and the fallbacks; Swift only applies the chosen code (`AppLanguageApplier`).
public nonisolated struct AppLanguageSetting {
    public nonisolated init() {}

    /// The value that means "follow macOS".
    public static let systemValue = "system"

    /// The chosen locale code, or nil for System, a missing key or a value cmux does not ship.
    static func parse(_ root: JSONValue) -> (String?, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (nil, nil) }
        guard let text = value.stringValue, values.contains(text) else {
            return (nil, SettingsDiagnostic(kind: .invalidValue, path: "app.language", message: "expected \"system\" or a shipped locale"))
        }
        return (text == systemValue ? nil : text, nil)
    }
}
