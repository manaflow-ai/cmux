public import CmuxNextDesign
import Foundation

/// `appearance.accent` in cmux.json: where the chrome's accent (selection, focus ring, the action
/// color) comes from (`CmuxTheme.ThemeAccent`). "theme" (the default) is the palette's signature
/// hue; "neutral" is the theme's foreground without hue; a color name is that ANSI slot.
public struct AccentSetting: Sendable {
    public let configPath = ["appearance", "accent"]
    public let fallback = ThemeAccent.theme

    public init() {}

    /// A missing key is the default with no diagnostic; a bad value is the default plus a
    /// diagnostic.
    func parse(_ root: JSONValue) -> (ThemeAccent, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let accent = ThemeAccent(rawValue: text) else {
            let choices = ThemeAccent.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "appearance.accent", message: "expected one of \(choices)"))
        }
        return (accent, nil)
    }
}
