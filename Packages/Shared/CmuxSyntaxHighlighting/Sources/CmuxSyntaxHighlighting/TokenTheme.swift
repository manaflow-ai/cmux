/// Light or dark token appearance for File Preview.
///
/// Surface (panel) colors stay on Ghostty `PanelAppearance`. Highlightr still
/// tokenizes with bundled `xcode` / `xcode-dark` CSS; ``HighlightColorRemapper``
/// then paints ``palette``.
public struct TokenTheme: Sendable, Equatable {
    private let paletteValue: TokenPalette
    private let highlightrThemeNameValue: String
    private let sourceColorMapValue: [String: TokenRole]

    private init(
        palette: TokenPalette,
        highlightrThemeName: String,
        sourceColorMap: [String: TokenRole]
    ) {
        paletteValue = palette
        highlightrThemeNameValue = highlightrThemeName
        sourceColorMapValue = sourceColorMap
    }

    /// Built-in light token theme.
    public static let light = TokenTheme(
        palette: .cmuxLight,
        highlightrThemeName: "xcode",
        sourceColorMap: Self.lightSourceColorMap
    )

    /// Built-in dark token theme.
    public static let dark = TokenTheme(
        palette: .cmuxDark,
        highlightrThemeName: "xcode-dark",
        sourceColorMap: Self.darkSourceColorMap
    )

    /// Creates a theme with an alternate semantic palette and the source CSS
    /// map for `base`.
    ///
    /// - Parameters:
    ///   - base: Light or dark Highlightr source theme.
    ///   - palette: Semantic colors to apply after tokenization.
    public init(base: TokenTheme, palette: TokenPalette) {
        self.init(
            palette: palette,
            highlightrThemeName: base.highlightrThemeName,
            sourceColorMap: base.sourceColorMap
        )
    }
    /// Product colors applied after Highlightr tokenization.
    public var palette: TokenPalette { paletteValue }

    /// Highlightr bundled CSS name used only as a tokenizer.
    public var highlightrThemeName: String { highlightrThemeNameValue }

    /// Hex keys produced by the Highlightr source theme, mapped to roles.
    ///
    /// Values come from Highlightr 2.3.0 `xcode.min.css` / `xcode-dark.min.css`.
    public var sourceColorMap: [String: TokenRole] { sourceColorMapValue }

    private static let lightSourceColorMap: [String: TokenRole] = [
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

    private static let darkSourceColorMap: [String: TokenRole] = [
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
