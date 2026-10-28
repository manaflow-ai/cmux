public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

/// Where the group colors draw in a theme scope. Groups use Lawrence's fixed
/// palette (`GroupColor.rgb(_:dark:)`, the Chrome tab group colors of #15516)
/// whatever the theme; the scope only picks the light or dark variant
/// (Lawrence 2026-10-13: familiar group colors first, so the theme-derived
/// group palette of #18991 and #19179 is no longer the default).
extension GroupColor {
    /// The order the group editor offers: none, then the palette.
    public static let editorOrder: [GroupColor] = [.grey, .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]

    /// The token's color in `tokens`' ANSI palette; nil for grey. Agent
    /// presence marks use it (`AgentPresenceColor`); groups do not.
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

    /// The color itself in `tokens`' light or dark variant: group lines, dots, swatches and marks.
    nonisolated public func swatchRGB(_ tokens: ThemeTokens) -> ThemeRGB { rgb(.swatch, dark: tokens.isDark) }

    /// The background that carries a group's name, in `tokens`' variant: the
    /// sidebar header bar and the tab group chip.
    nonisolated public func fillRGB(_ tokens: ThemeTokens) -> ThemeRGB { rgb(.fill, dark: tokens.isDark) }

    /// The color where it marks content (tab tints, space avatars and dots, profile dots).
    public var markColor: NSColor { swatchRGB(Self.activeTokens).nsColor }

    /// The tab group chip's fill in the active theme scope.
    public var chipFill: NSColor { fillRGB(Self.activeTokens).nsColor }

    /// The group's color where it draws as a line or dot: the members' line,
    /// the tab group underline and the editors' swatches.
    public var headerFill: NSColor { swatchRGB(Self.activeTokens).nsColor }

    /// The color as a palette ball in the active theme scope (the app theme outside one).
    public var ballRGB: ThemeRGB { swatchRGB(Self.activeTokens) }

    /// The sidebar header bar's color before its ink contrast step (`GroupTint.headerChip`).
    nonisolated func headerRGB(_ tokens: ThemeTokens) -> ThemeRGB { fillRGB(tokens) }

    nonisolated static func ink(on fill: ThemeRGB) -> ThemeRGB {
        let dark = ThemeRGB(hex: 0x1F1F1F)
        return fill.contrast(with: dark) >= fill.contrast(with: .white) ? dark : .white
    }

    private static var activeTokens: ThemeTokens { ThemeContext.active ?? ThemeScope.app.tokens }
}
