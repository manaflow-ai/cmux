/// Product token colors for File Preview.
///
/// Surfaces stay on Ghostty `PanelAppearance`. These values only color
/// tokens, the caret-line wash, and indent guides. Keyword / type / regexp
/// channels are the published cmux product blues from `web/app/globals.css`:
/// `#0088FF` / `#0073D9` / `#006DC1` in light, `#0091FF` in dark.
public struct TokenPalette: Sendable, Equatable {
    /// Default / unsubstituted text.
    public let foreground: TokenColor
    /// Comments and quotes.
    public let comment: TokenColor
    /// Keywords, tags, and language literals. Product blue.
    public let keyword: TokenColor
    /// Types, class names, and builtins. Lighter/darker step of product blue.
    public let type: TokenColor
    /// String literals. Warm sand — the one complementary hue so the
    /// page does not collapse into monochrome blue.
    public let string: TokenColor
    /// Numbers, symbols, and titles. Cool aqua in the same family as the blue.
    public let number: TokenColor
    /// Attributes, JSON keys, and selectors.
    public let attribute: TokenColor
    /// Variables and template variables.
    public let variable: TokenColor
    /// Regular expressions and links.
    public let regexp: TokenColor
    /// Product-blue caret-line wash. Chrome applies ``currentLineAlpha``.
    public let currentLine: TokenColor
    /// Opacity for ``currentLine`` (0...1). Matches web `::selection` (~12%).
    public let currentLineAlpha: Double
    /// Indent-guide stroke.
    public let indentGuide: TokenColor
    /// Opacity for ``indentGuide`` (0...1).
    public let indentGuideAlpha: Double

    /// Dark palette for `#0A0A0A` / `#171717` surfaces.
    public static let cmuxDark = TokenPalette(
        foreground: TokenColor(red: 0xED, green: 0xED, blue: 0xED),
        comment: TokenColor(red: 0x8A, green: 0x8F, blue: 0x96),
        keyword: TokenColor(red: 0x00, green: 0x91, blue: 0xFF),
        type: TokenColor(red: 0x8E, green: 0xC5, blue: 0xFF),
        string: TokenColor(red: 0xE0, green: 0xB8, blue: 0x6A),
        number: TokenColor(red: 0x5E, green: 0xD0, blue: 0xC8),
        attribute: TokenColor(red: 0xB4, green: 0xD4, blue: 0xF5),
        variable: TokenColor(red: 0xC8, green: 0xCE, blue: 0xD6),
        regexp: TokenColor(red: 0x4E, green: 0xA3, blue: 0xFF),
        currentLine: TokenColor(red: 0x00, green: 0x91, blue: 0xFF),
        currentLineAlpha: 0.12,
        indentGuide: TokenColor(red: 0xA3, green: 0xA3, blue: 0xA3),
        indentGuideAlpha: 0.35
    )

    /// Light palette for `#FAFAFA` / `#F5F5F5` surfaces.
    public static let cmuxLight = TokenPalette(
        foreground: TokenColor(red: 0x17, green: 0x17, blue: 0x17),
        comment: TokenColor(red: 0x73, green: 0x73, blue: 0x73),
        keyword: TokenColor(red: 0x00, green: 0x6D, blue: 0xC1),
        type: TokenColor(red: 0x00, green: 0x73, blue: 0xD9),
        string: TokenColor(red: 0x8A, green: 0x5A, blue: 0x00),
        number: TokenColor(red: 0x0F, green: 0x76, blue: 0x6E),
        attribute: TokenColor(red: 0x0C, green: 0x4A, blue: 0x6E),
        variable: TokenColor(red: 0x3F, green: 0x4A, blue: 0x55),
        regexp: TokenColor(red: 0x00, green: 0x88, blue: 0xFF),
        currentLine: TokenColor(red: 0x00, green: 0x88, blue: 0xFF),
        currentLineAlpha: 0.10,
        indentGuide: TokenColor(red: 0x73, green: 0x73, blue: 0x73),
        indentGuideAlpha: 0.40
    )

    /// Color assigned to `role` in this palette.
    ///
    /// - Parameter role: Semantic token role.
    /// - Returns: The color for that role.
    public func color(for role: TokenRole) -> TokenColor {
        switch role {
        case .foreground:
            return foreground
        case .comment:
            return comment
        case .keyword:
            return keyword
        case .type:
            return type
        case .string:
            return string
        case .number:
            return number
        case .attribute:
            return attribute
        case .variable:
            return variable
        case .regexp:
            return regexp
        }
    }
}
