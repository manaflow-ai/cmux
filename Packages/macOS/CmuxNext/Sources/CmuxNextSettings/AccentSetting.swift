public import CmuxNextDesignTokens
import Foundation

/// `appearance.accent` in cmux.json: where the chrome's accent (selection, focus ring, the action
/// color) comes from (`CmuxTheme.ThemeAccent`). "neutral" (the default) is the theme's foreground
/// without hue; "theme" is the palette's signature hue; a color name is that ANSI slot.
public struct AccentSetting: Sendable {
    public let configPath = ["appearance", "accent"]
    public let fallback = ThemeAccent.neutral

    /// Art Color (cx-t2x.5): the accent takes the hue of the art a window shows. The tokens' own
    /// accent stays neutral; `ThemeStore.accentFollowsArt` brings in the art's hue per scope.
    public static let artID = "art"

    public init() {}

    /// Whether `appearance.accent` is Art Color.
    public static func followsArt(_ root: JSONValue) -> Bool {
        root.value(at: AccentSetting().configPath)?.stringValue == artID
    }

    /// A missing key is the default with no diagnostic; a bad value is the default plus a
    /// diagnostic.
    func parse(_ root: JSONValue) -> (ThemeAccent, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        if value.stringValue == Self.artID { return (fallback, nil) }
        guard let text = value.stringValue, let accent = ThemeAccent(rawValue: text) else {
            let choices = ThemeAccent.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "appearance.accent", message: "expected one of \(choices)"))
        }
        return (accent, nil)
    }
}
