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

    /// A resting workspace row's color bar stands at most this far from the sidebar (WCAG contrast), so the title
    /// (about 9:1 or more) reads first.
    nonisolated public static let railRestContrast = 2.2
    /// A selected workspace row's color bar stands at most this far from the sidebar: stronger than at rest.
    nonisolated public static let railEmphasizedContrast = 3.0

    /// A workspace row's color bar (`workspaceColors.indicatorStyle` `leftRail`, the default) in `tokens`.
    ///
    /// The swatch is taken toward the sidebar until it stands at most ``railRestContrast`` from it
    /// (``railEmphasizedContrast`` when `emphasized`, a selected row), so a picked color reads as a quiet mark
    /// beside the title in every theme, light and dark, never as loud as the title (Lawrence 2026-11-20, "these
    /// colors look horrible by default": the full-strength vibrant blue drew at 7:1). A swatch already that quiet
    /// is kept as it is, so a light hue never fades out.
    ///
    /// - Parameters:
    ///   - tokens: The theme the row draws in.
    ///   - emphasized: Whether the row is selected (or a drop target), so its bar steps up.
    ///   - muted: Halve the swatch's OKLCH chroma first, for a softer, grayer bar at the same contrast.
    /// - Returns: The bar's opaque color.
    nonisolated public func railRGB(_ tokens: ThemeTokens, emphasized: Bool, muted: Bool = false) -> ThemeRGB {
        let ground = tokens.sidebarBackground.composited(over: tokens.windowBackground.withAlpha(1)).withAlpha(1)
        var swatch = swatchRGB(tokens).withAlpha(1)
        if muted {
            // Half the chroma at the same lightness and hue: a softer, grayer hue that still names the color.
            let lch = swatch.oklch
            swatch = ThemeRGB(oklchLightness: lch.lightness, chroma: lch.chroma * 0.5, hue: lch.hue)
        }
        let target = emphasized ? Self.railEmphasizedContrast : Self.railRestContrast
        guard swatch.contrast(with: ground) > target else { return swatch }
        // Contrast falls steadily as the swatch moves toward the ground, so the least move that reaches the target is
        // found by halving.
        var (low, high) = (0.0, 1.0)
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if swatch.mixed(toward: ground, mid).contrast(with: ground) > target { low = mid } else { high = mid }
        }
        return swatch.mixed(toward: ground, high)
    }

    /// ``railRGB(_:emphasized:muted:)`` in the active theme scope (the app theme outside one).
    ///
    /// - Parameters:
    ///   - emphasized: Whether the row is selected (or a drop target).
    ///   - muted: Halve the swatch's chroma first (the Sidebar States Playground's muted looks).
    public func railColor(emphasized: Bool, muted: Bool = false) -> NSColor {
        railRGB(Self.activeTokens, emphasized: emphasized, muted: muted).nsColor
    }

    /// The color where it marks content (tab tints, space avatars and dots, profile dots).
    public var markColor: NSColor { swatchRGB(Self.activeTokens).nsColor }

    /// The tab group chip's fill in the active theme scope.
    public var chipFill: NSColor { fillRGB(Self.activeTokens).nsColor }

    /// The group's color where it draws as a line or dot: the members' line,
    /// the tab group underline and the editors' swatches.
    public var headerFill: NSColor { swatchRGB(Self.activeTokens).nsColor }

    /// The color as a palette ball in the active theme scope (the app theme outside one).
    public var ballRGB: ThemeRGB { swatchRGB(Self.activeTokens) }

    /// The order the app gives new workspace groups, spaces and browser
    /// profiles their colors: the palette in its own order, without grey and
    /// blue (the no-blue rule covers what the app picks by itself).
    nonisolated public static let automaticOrder: [GroupColor] = allCases.filter { $0 != .grey && $0 != .blue }

    /// The sidebar header bar's color before its ink contrast step (`GroupTint.headerChip`).
    nonisolated func headerRGB(_ tokens: ThemeTokens) -> ThemeRGB { fillRGB(tokens) }

    nonisolated static func ink(on fill: ThemeRGB) -> ThemeRGB {
        let dark = ThemeRGB(hex: 0x1F1F1F)
        return fill.contrast(with: dark) >= fill.contrast(with: .white) ? dark : .white
    }

    private static var activeTokens: ThemeTokens { ThemeContext.active ?? ThemeScope.app.tokens }
}
