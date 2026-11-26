/// Light or dark token appearance for File Preview.
///
/// Surface (panel) colors stay on Ghostty `PanelAppearance`. Highlightr still
/// tokenizes with bundled `xcode` / `xcode-dark` CSS; ``HighlightColorRemapper``
/// then paints ``palette``.
public enum TokenTheme: Sendable, Equatable {
    /// Light cmux token palette (Highlightr source: `xcode`).
    case light
    /// Dark cmux token palette (Highlightr source: `xcode-dark`).
    case dark

    /// Product colors applied after Highlightr tokenization.
    public var palette: TokenPalette {
        switch self {
        case .light:
            return .cmuxLight
        case .dark:
            return .cmuxDark
        }
    }

    /// Highlightr bundled CSS name used only as a tokenizer.
    public var highlightrThemeName: String {
        switch self {
        case .light:
            return "xcode"
        case .dark:
            return "xcode-dark"
        }
    }

    /// Hex keys produced by the Highlightr source theme, mapped to roles.
    ///
    /// Values come from Highlightr 2.3.0 `xcode.min.css` / `xcode-dark.min.css`.
    public var sourceColorMap: [String: TokenRole] {
        switch self {
        case .light:
            return [
                "000000": .foreground,
                "007400": .comment,
                "AA0D91": .keyword,
                "3F6E74": .variable,
                "C41A16": .string,
                "0E0EFF": .regexp,
                "1C00CF": .number,
                "643820": .attribute,
                "5C2699": .type,
                "836C28": .attribute,
                "9B703F": .attribute,
                "C0C0C0": .comment,
            ]
        case .dark:
            return [
                "FFFFFF": .foreground,
                "6C7986": .comment,
                "FC5FA3": .keyword,
                "FC6A5D": .string,
                "5482FF": .regexp,
                "41A1C0": .number,
                "D0A8FF": .type,
                "BF8555": .attribute,
                "9B703F": .attribute,
            ]
        }
    }
}
