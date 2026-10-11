import CmuxNextDesign
import Foundation

/// `appearance.theme` in cmux.json: cmux's own theme, one Ghostty theme name
/// (`Nord`) or a light/dark pair (`light:Rose Pine Dawn,dark:Rose Pine`).
/// Absent or empty means the Ghostty config's theme. Onboarding, the
/// Settings page and the palette write it; the App applies it
/// as a Ghostty override, so terminals and chrome follow live.
public struct AppThemeSetting: Sendable {
    public let configPath = ["appearance", "theme"]

    public init() {}

    /// Whether `text` is a theme spec Ghostty can take (`ThemeSpec`): no
    /// characters that could start another config line.
    public func isValid(_ text: String) -> Bool {
        ThemeSpec(text) != nil
    }

    /// A missing or empty key is the Ghostty config's theme with no
    /// diagnostic; a bad value is the same plus a diagnostic. A name this
    /// build does not ship (a newer Ghostty's, a user's own theme file)
    /// loads as written.
    func parse(_ root: JSONValue) -> (String?, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (nil, nil) }
        let problem = SettingsDiagnostic(kind: .invalidValue, path: "appearance.theme",
                                         message: "expected a Ghostty theme name or \"light:<theme>,dark:<theme>\"")
        guard let text = value.stringValue else { return (nil, problem) }
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return (nil, nil) }
        guard let spec = ThemeSpec(text) else { return (nil, problem) }
        return (spec.raw, nil)
    }
}
