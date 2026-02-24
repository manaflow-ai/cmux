import AppKit
import Neon

enum SyntaxHighlightTheme {

    // MARK: - Dracula palette
    // https://draculatheme.com/contribute

    private static let draculaBackground  = NSColor(srgbRed: 0.157, green: 0.165, blue: 0.212, alpha: 1) // #282A36
    private static let draculaForeground  = NSColor(srgbRed: 0.973, green: 0.973, blue: 0.949, alpha: 1) // #F8F8F2
    private static let draculaComment     = NSColor(srgbRed: 0.384, green: 0.447, blue: 0.643, alpha: 1) // #6272A4
    private static let draculaCyan        = NSColor(srgbRed: 0.545, green: 0.914, blue: 0.992, alpha: 1) // #8BE9FD
    private static let draculaGreen       = NSColor(srgbRed: 0.314, green: 0.980, blue: 0.482, alpha: 1) // #50FA7B
    private static let draculaOrange      = NSColor(srgbRed: 1.000, green: 0.722, blue: 0.424, alpha: 1) // #FFB86C
    private static let draculaPink        = NSColor(srgbRed: 1.000, green: 0.475, blue: 0.776, alpha: 1) // #FF79C6
    private static let draculaPurple      = NSColor(srgbRed: 0.741, green: 0.576, blue: 0.976, alpha: 1) // #BD93F9
    private static let draculaRed         = NSColor(srgbRed: 1.000, green: 0.333, blue: 0.333, alpha: 1) // #FF5555
    private static let draculaYellow      = NSColor(srgbRed: 0.945, green: 0.980, blue: 0.549, alpha: 1) // #F1FA8C

    // MARK: - Attribute provider

    static func attributeProvider(baseFont: NSFont) -> TokenAttributeProvider {
        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)

        return { token in
            var attrs: [NSAttributedString.Key: Any] = [.font: baseFont]
            let name = token.name

            // Markdown / prose
            if name.hasPrefix("text.title") {
                attrs[.foregroundColor] = draculaPurple
                attrs[.font] = boldFont
            } else if name.hasPrefix("text.strong") {
                attrs[.foregroundColor] = draculaOrange
                attrs[.font] = boldFont
            } else if name.hasPrefix("text.emphasis") {
                attrs[.foregroundColor] = draculaYellow
                attrs[.font] = italicFont
            } else if name.hasPrefix("text.literal") {
                attrs[.foregroundColor] = draculaYellow
            } else if name.hasPrefix("text.uri") {
                attrs[.foregroundColor] = draculaCyan
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            } else if name.hasPrefix("text.reference") {
                attrs[.foregroundColor] = draculaCyan

            // Code
            } else if name.hasPrefix("keyword") || name == "conditional" || name == "repeat"
                        || name == "include" || name == "exception" || name == "preproc"
                        || name == "storageclass" {
                attrs[.foregroundColor] = draculaPink
            } else if name.hasPrefix("string") {
                attrs[.foregroundColor] = draculaYellow
            } else if name.hasPrefix("comment") || name == "spell" {
                attrs[.foregroundColor] = draculaComment
                attrs[.font] = italicFont
            } else if name.hasPrefix("type") || name.hasPrefix("constructor")
                        || name == "namespace" || name == "module" {
                attrs[.foregroundColor] = draculaCyan
                attrs[.font] = italicFont
            } else if name.hasPrefix("function") || name.hasPrefix("method") {
                attrs[.foregroundColor] = draculaGreen
            } else if name.hasPrefix("number") || name.hasPrefix("float")
                        || name == "boolean" || name.hasPrefix("character") {
                attrs[.foregroundColor] = draculaPurple
            } else if name.hasPrefix("constant") {
                attrs[.foregroundColor] = draculaPurple
            } else if name.hasPrefix("parameter") {
                attrs[.foregroundColor] = draculaOrange
                attrs[.font] = italicFont
            } else if name.hasPrefix("attribute") || name.hasPrefix("label") {
                attrs[.foregroundColor] = draculaGreen
                attrs[.font] = italicFont
            } else if name.hasPrefix("tag") {
                attrs[.foregroundColor] = draculaPink
            } else if name.hasPrefix("escape") {
                attrs[.foregroundColor] = draculaPink
            } else if name.hasPrefix("punctuation") || name == "delimiter" {
                // foreground default
            } else if name.hasPrefix("embedded") {
                attrs[.foregroundColor] = draculaPink
            } else if name.hasPrefix("variable.builtin") {
                attrs[.foregroundColor] = draculaPurple
                attrs[.font] = italicFont
            }

            // variable, property, field, operator — all use default foreground

            return attrs
        }
    }
}
