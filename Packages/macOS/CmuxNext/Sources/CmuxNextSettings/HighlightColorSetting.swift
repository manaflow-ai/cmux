import Foundation

/// `appearance.highlightColor` in cmux.json: the one highlight (selected text) color of the whole
/// app, over the terminal theme's `selection-background`. It reaches the terminal as that Ghostty
/// color, so the chrome's text fields, the omnibar and every page (Markdown, editors, diffs), which
/// read the terminal's selection color (`ThemeTokens.textSelection`), follow it. Unset (the
/// default) keeps the theme's own. The Home chat's Messages bubbles keep their own highlight.
public nonisolated struct HighlightColorSetting: Sendable {
    public let configPath = ["appearance", "highlightColor"]

    public init() {}

    /// `#rrggbb`, lowercased; nil when unset. A bad value is nil plus a diagnostic. `#RRGGBBAA`
    /// (the Settings color well can write one) drops the alpha: Ghostty's selection is opaque.
    func parse(_ root: JSONValue) -> (String?, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (nil, nil) }
        if let text = value.stringValue, let color = Self.color(text) { return (color, nil) }
        return (nil, SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                        message: "expected \"#RRGGBB\""))
    }

    private static func color(_ text: String) -> String? {
        let hex = text.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }
        guard hex.count == 6 || hex.count == 8, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return "#" + hex.prefix(6).lowercased()
    }
}
