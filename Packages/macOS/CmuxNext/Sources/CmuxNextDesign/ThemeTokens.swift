import Foundation

/// Every chrome color, derived from the terminal theme (`ThemeInput`).
///
/// Surfaces that sit next to the terminal (window, sidebar, tab strip) are
/// the terminal background itself, so there is no seam. Fills are the
/// foreground at a low alpha, so they read as a slightly lighter (dark
/// themes) or darker (light themes) version of the same surface. Text is
/// the foreground, muted toward the background only as far as WCAG contrast
/// allows. No accent hue: blue appears only if the theme's own colors are
/// blue, and the status colors come from the theme's ANSI palette.
public nonisolated struct ThemeTokens: Hashable, Sendable {
    /// Dark when the background is darker than the foreground.
    public var isDark: Bool

    // Surfaces
    /// Window background: the terminal background (with its opacity).
    public var windowBackground: ThemeRGB
    /// Sidebar: the same surface as the window, no panel.
    public var sidebarBackground: ThemeRGB
    /// Behind terminal and browser content.
    public var contentBackground: ThemeRGB
    /// Fields and toolbars that need a faint lift (omnibar, find bar).
    public var chromeBackground: ThemeRGB
    /// Floating cards (palette, hover card, editors) under or instead of glass.
    public var elevatedBackground: ThemeRGB

    // Text
    public var textPrimary: ThemeRGB
    /// Captions, inactive titles. At least 4.5:1 on every fill.
    public var textSecondary: ThemeRGB
    /// Hints and placeholders. At least 3:1 on every fill.
    public var textTertiary: ThemeRGB

    // Fills (translucent foreground over the surface)
    public var hoverFill: ThemeRGB
    public var selectionFill: ThemeRGB
    /// Multi-selected rows that are not the active one.
    public var secondarySelectionFill: ThemeRGB
    public var pressedFill: ThemeRGB
    public var badgeFill: ThemeRGB
    public var separator: ThemeRGB
    public var focusRing: ThemeRGB
    /// Tint laid over Liquid Glass so it takes the theme's cast.
    public var glassTint: ThemeRGB
    public var shadow: ThemeRGB
    /// Selected text in chrome text fields (the terminal's selection color
    /// when the config sets one).
    public var textSelection: ThemeRGB

    // Status, from the ANSI palette
    public var attention: ThemeRGB
    public var danger: ThemeRGB
    public var success: ThemeRGB
    /// ANSI 0...15.
    public var ansi: [ThemeRGB]

    public var backgroundOpacity: Double
    public var backgroundBlur: Int

    /// Minimum contrast for primary and secondary chrome text.
    public static let minimumTextContrast = 4.5
    /// Minimum contrast for tertiary text and status marks.
    public static let minimumMarkContrast = 3.0

    public static let fallback = derive(from: .ghosttyDefault)

    public static func derive(from input: ThemeInput) -> ThemeTokens {
        let bg = input.background
        let isDark = bg.relativeLuminance < input.foreground.relativeLuminance
        let fg = input.foreground

        let hover = fg.withAlpha(isDark ? 0.06 : 0.05)
        let selection = fg.withAlpha(isDark ? 0.10 : 0.08)
        let pressed = fg.withAlpha(isDark ? 0.14 : 0.11)
        // Text must hold its contrast on the strongest fill it can sit on.
        let worstSurface = pressed.composited(over: bg)
        let primary = readable(fg, over: worstSurface, minimum: minimumTextContrast)
        let secondary = muted(primary, toward: bg, upTo: 0.38, over: worstSurface, minimum: minimumTextContrast)
        let tertiary = muted(primary, toward: bg, upTo: 0.55, over: worstSurface, minimum: minimumMarkContrast)

        let palette = input.palette.count >= 8 ? input.palette : ThemeInput.ghosttyDefault.palette
        func status(_ index: Int) -> ThemeRGB { readable(palette[index], over: bg, minimum: minimumMarkContrast) }

        let surface = bg.withAlpha(input.backgroundOpacity)
        return ThemeTokens(
            isDark: isDark,
            windowBackground: surface,
            sidebarBackground: surface,
            contentBackground: surface,
            chromeBackground: bg.mixed(toward: fg, isDark ? 0.05 : 0.035),
            elevatedBackground: bg.mixed(toward: fg, isDark ? 0.07 : 0.02),
            textPrimary: primary,
            textSecondary: secondary,
            textTertiary: tertiary,
            hoverFill: hover,
            selectionFill: selection,
            secondarySelectionFill: fg.withAlpha(isDark ? 0.07 : 0.055),
            pressedFill: pressed,
            badgeFill: fg.withAlpha(isDark ? 0.14 : 0.10),
            separator: fg.withAlpha(isDark ? 0.08 : 0.07),
            focusRing: fg.withAlpha(0.40),
            glassTint: bg.withAlpha(isDark ? 0.40 : 0.30),
            shadow: bg.mixed(toward: .black, 0.85),
            textSelection: input.selectionBackground ?? bg.mixed(toward: fg, 0.22),
            attention: status(3),
            danger: status(1),
            success: status(2),
            ansi: palette,
            backgroundOpacity: input.backgroundOpacity,
            backgroundBlur: input.backgroundBlur
        )
    }

    /// `color`, pushed away from `surface` (toward white or black) until it
    /// reaches `minimum` contrast.
    static func readable(_ color: ThemeRGB, over surface: ThemeRGB, minimum: Double) -> ThemeRGB {
        guard color.contrast(with: surface) < minimum else { return color }
        let pole: ThemeRGB = surface.relativeLuminance < 0.18 ? .white : .black
        var step = 0.0
        var candidate = color
        while step < 1, candidate.contrast(with: surface) < minimum {
            step += 0.02
            candidate = color.mixed(toward: pole, step)
        }
        return candidate
    }

    /// `color` mixed toward `target` as far as `limit` allows while keeping
    /// `minimum` contrast over `surface`.
    static func muted(_ color: ThemeRGB, toward target: ThemeRGB, upTo limit: Double, over surface: ThemeRGB, minimum: Double) -> ThemeRGB {
        var fraction = limit
        while fraction > 0 {
            let candidate = color.mixed(toward: target, fraction)
            if candidate.contrast(with: surface) >= minimum { return candidate }
            fraction -= 0.01
        }
        return color
    }
}
