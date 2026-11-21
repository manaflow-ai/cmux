/// Semantic token colors for File Preview.
///
/// Surfaces stay on Ghostty `PanelAppearance`. Built-in values provide a
/// readable fallback; configured Ghostty ANSI colors can replace semantic
/// token roles through ``init(ansiPalette:foreground:fallback:)``. These
/// values also color the caret-line wash and indent guides.
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
    /// Variables and template variables, using the resolved terminal foreground
    /// so light palettes do not turn them white on a light editor surface.
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

    private init(
        foreground: TokenColor,
        comment: TokenColor,
        keyword: TokenColor,
        type: TokenColor,
        string: TokenColor,
        number: TokenColor,
        attribute: TokenColor,
        variable: TokenColor,
        regexp: TokenColor,
        currentLine: TokenColor,
        currentLineAlpha: Double,
        indentGuide: TokenColor,
        indentGuideAlpha: Double
    ) {
        self.foreground = foreground
        self.comment = comment
        self.keyword = keyword
        self.type = type
        self.string = string
        self.number = number
        self.attribute = attribute
        self.variable = variable
        self.regexp = regexp
        self.currentLine = currentLine
        self.currentLineAlpha = currentLineAlpha
        self.indentGuide = indentGuide
        self.indentGuideAlpha = indentGuideAlpha
    }

    /// Creates a token palette from Ghostty's sixteen-color ANSI palette.
    ///
    /// The semantic mapping follows the conventional terminal color roles:
    /// red for keywords, green for literals and cyan for strings. Missing
    /// entries fall back to the selected built-in palette, so partial
    /// configurations remain readable.
    ///
    /// - Parameters:
    ///   - ansiPalette: ANSI color indexes (`0...15`) resolved by Ghostty.
    ///   - foreground: Resolved terminal foreground color.
    ///   - fallback: Built-in palette used for missing ANSI entries and chrome.
    public init(
        ansiPalette: [Int: TokenColor],
        foreground: TokenColor,
        fallback: TokenPalette
    ) {
        self.foreground = foreground
        self.comment = Self.ansiColor(8, in: ansiPalette, fallback: fallback.comment)
        self.keyword = Self.ansiColor(1, in: ansiPalette, fallback: fallback.keyword)
        self.type = Self.ansiColor(5, in: ansiPalette, fallback: fallback.type)
        self.string = Self.ansiColor(6, in: ansiPalette, fallback: fallback.string)
        self.number = Self.ansiColor(3, in: ansiPalette, fallback: fallback.number)
        self.attribute = Self.ansiColor(4, in: ansiPalette, fallback: fallback.attribute)
        self.variable = foreground
        self.regexp = Self.ansiColor(2, in: ansiPalette, fallback: fallback.regexp)
        self.currentLine = fallback.currentLine
        self.currentLineAlpha = fallback.currentLineAlpha
        self.indentGuide = fallback.indentGuide
        self.indentGuideAlpha = fallback.indentGuideAlpha
    }

    private static func ansiColor(
        _ index: Int,
        in palette: [Int: TokenColor],
        fallback: TokenColor
    ) -> TokenColor {
        palette[index] ?? fallback
    }

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
