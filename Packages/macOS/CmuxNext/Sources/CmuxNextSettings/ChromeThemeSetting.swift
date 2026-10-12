import CmuxNextDesign
import Foundation

/// `appearance.appTheme` in cmux.json: the theme cmux's own surfaces (pages today, the native
/// chrome next) take their app tokens from (`CmuxTheme.AppTheme`), apart from the terminal theme.
/// `followTerminal` (the default) uses each scope's terminal theme; otherwise one Ghostty theme
/// name or a light/dark pair, like `appearance.theme`.
public struct ChromeThemeSetting: Sendable {
    public let configPath = ["appearance", "appTheme"]
    /// The default: the app theme follows the terminal theme.
    public static let followTerminal = "followTerminal"

    public init() {}

    /// `followTerminal`, or a theme spec Ghostty can take.
    public func isValid(_ text: String) -> Bool {
        text == Self.followTerminal || ThemeSpec(text) != nil
    }

    /// Nil (follow the terminal theme) for a missing, empty or `followTerminal` value; a bad value
    /// is the same plus a diagnostic.
    func parse(_ root: JSONValue) -> (String?, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (nil, nil) }
        let problem = SettingsDiagnostic(kind: .invalidValue, path: "appearance.appTheme",
                                         message: "expected \"followTerminal\", a Ghostty theme name or \"light:<theme>,dark:<theme>\"")
        guard let text = value.stringValue else { return (nil, problem) }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == Self.followTerminal { return (nil, nil) }
        guard let spec = ThemeSpec(trimmed) else { return (nil, problem) }
        return (spec.raw, nil)
    }
}
