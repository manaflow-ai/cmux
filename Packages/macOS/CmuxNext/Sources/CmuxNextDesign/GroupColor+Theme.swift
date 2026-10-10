public import AppKit
public import CmuxTheme

/// Workspace group colors from the active Ghostty theme (cx-rcby, Lawrence
/// 2026-10-08: "make groups like this", the Chrome tab group chip): each
/// token is one of the theme's ANSI colors, so groups follow the palette
/// the terminal draws with; grey is "none". The color is kept readable over
/// the sidebar (`ThemeTokens.readable`), like the status colors.
extension GroupColor {
    /// The order the group editor offers: none, then the palette.
    public static let editorOrder: [GroupColor] = [.grey, .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]

    /// The token's color in `tokens`' ANSI palette; nil for grey (none).
    nonisolated public func themeRGB(_ tokens: ThemeTokens) -> ThemeRGB? {
        let p = tokens.ansi
        guard p.count >= 8 else { return nil }
        let rgb: ThemeRGB? = switch self {
        case .grey: nil
        case .red: p[1]
        case .green: p[2]
        case .yellow: p[3]
        case .blue: p[4]
        case .purple: p[5]
        case .cyan: p[6]
        // Bright magenta when the theme names 16 colors.
        case .pink: p.count > 13 ? p[13] : p[5].mixed(toward: p[1], 0.35)
        case .orange: p[1].mixed(toward: p[3], 0.5)
        }
        return rgb.map { ThemeTokens.readable($0.withAlpha(1), over: tokens.sidebarBackground, minimum: ThemeTokens.minimumMarkContrast) }
    }

    /// The token's color in the active theme scope (the app theme outside
    /// one): the member bar and the editor's dot. Nil for grey (none).
    public var themed: NSColor? { themeRGB(ThemeContext.active ?? ThemeScope.app.tokens)?.nsColor }

    /// The group chip's fill in the active theme scope: the color washed
    /// into the sidebar so the name stays primary text; none draws the
    /// neutral badge fill.
    public var themedChipFill: NSColor {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        guard let rgb = themeRGB(tokens) else { return Palette.badgeFill }
        return tokens.sidebarBackground.withAlpha(1).mixed(toward: rgb, tokens.isDark ? 0.34 : 0.26).nsColor
    }

    /// The group's color where it draws: the header's dot, the members'
    /// line and the editor's swatch (cx-q5jw, cx-25az, Leo 2026-10-10: theme
    /// colors, no pastels, no full header fill): the theme's palette color
    /// itself, kept readable over the sidebar. None is the sidebar's tonal step.
    public var headerFill: NSColor { headerRGB(ThemeContext.active ?? ThemeScope.app.tokens).nsColor }

    /// Text and glyphs on `headerFill`: black or white, whichever reads
    /// better on the color in this theme.
    public var headerInk: NSColor {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        guard themeRGB(tokens) != nil else { return Palette.textPrimary }
        return Self.ink(on: headerRGB(tokens)).nsColor
    }

    /// The order the app gives new groups their colors (cx-25az, Leo
    /// 2026-10-10: the terminal palette in a stable order): the ANSI
    /// accents by index, then the two mixed ones. Blue is left to people
    /// (the no-blue rule covers what the app picks by itself).
    nonisolated public static let automaticOrder: [GroupColor] = [.red, .green, .yellow, .purple, .cyan, .orange, .pink]

    nonisolated func headerRGB(_ tokens: ThemeTokens) -> ThemeRGB {
        themeRGB(tokens) ?? tokens.sidebarBackground.withAlpha(1).mixed(toward: tokens.isDark ? .white : .black, 0.12)
    }

    nonisolated static func ink(on fill: ThemeRGB) -> ThemeRGB {
        let dark = ThemeRGB(hex: 0x1F1F1F)
        return fill.contrast(with: dark) >= fill.contrast(with: .white) ? dark : .white
    }
}
