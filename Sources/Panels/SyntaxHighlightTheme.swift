import AppKit
import STPluginNeon

enum SyntaxHighlightTheme {

    // MARK: - Dracula palette
    // https://draculatheme.com/contribute

    private static let draculaForeground  = NSColor(srgbRed: 0.973, green: 0.973, blue: 0.949, alpha: 1) // #F8F8F2
    private static let draculaComment     = NSColor(srgbRed: 0.384, green: 0.447, blue: 0.643, alpha: 1) // #6272A4
    private static let draculaCyan        = NSColor(srgbRed: 0.545, green: 0.914, blue: 0.992, alpha: 1) // #8BE9FD
    private static let draculaGreen       = NSColor(srgbRed: 0.314, green: 0.980, blue: 0.482, alpha: 1) // #50FA7B
    private static let draculaOrange      = NSColor(srgbRed: 1.000, green: 0.722, blue: 0.424, alpha: 1) // #FFB86C
    private static let draculaPink        = NSColor(srgbRed: 1.000, green: 0.475, blue: 0.776, alpha: 1) // #FF79C6
    private static let draculaPurple      = NSColor(srgbRed: 0.741, green: 0.576, blue: 0.976, alpha: 1) // #BD93F9
    private static let draculaYellow      = NSColor(srgbRed: 0.945, green: 0.980, blue: 0.549, alpha: 1) // #F1FA8C

    // MARK: - Plugin-Neon theme

    static func neonTheme(baseFont: NSFont) -> Theme {
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)

        return Theme(
            colors: Theme.Colors(colors: [
                "plain":               draculaForeground,
                "variable":            draculaForeground,
                "operator":            draculaForeground,
                "punctuation.special": draculaForeground,

                "keyword":             draculaPink,
                "keyword.function":    draculaPink,
                "keyword.return":      draculaPink,
                "include":             draculaPink,

                "string":              draculaYellow,
                "text.literal":        draculaYellow,
                "boolean":             draculaPurple,
                "number":              draculaPurple,
                "variable.builtin":    draculaPurple,
                "constructor":         draculaPurple,

                "type":                draculaCyan,
                "text.title":          draculaPurple,
                "text.uri":            draculaCyan,

                "function.call":       draculaGreen,
                "method":              draculaGreen,

                "comment":             draculaComment,
                "parameter":           draculaOrange,
            ]),
            fonts: Theme.Fonts(fonts: [
                "plain":           baseFont,
                "comment":         italicFont,
                "type":            italicFont,
                "parameter":       italicFont,
                "variable.builtin": italicFont,
                "text.title":      boldFont,
            ])
        )
    }
}
