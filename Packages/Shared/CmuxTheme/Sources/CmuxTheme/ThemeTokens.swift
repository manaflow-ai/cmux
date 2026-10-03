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
public struct ThemeTokens: Hashable, Sendable {
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
    /// Every pane's tab strip: a shade darker than the window in light
    /// themes too, so the strips read as quiet bands (a pure black window
    /// has no darker shade; there the strip matches it).
    public var stripBackground: ThemeRGB
    /// The sidebar's tonal step: a translucent layer over the window's one
    /// backdrop (the solid background, or the material and its tint), the
    /// foreground at the same 4% the agent pane's sidebar uses.
    public var sidebarStep: ThemeRGB
    /// The tab strip's tonal step over the window's backdrop: black, so
    /// over the opaque background it composites to `stripBackground`.
    public var stripStep: ThemeRGB

    // Text
    /// Titles and body text: the foreground, pushed to 4.5:1 when needed.
    public var textPrimary: ThemeRGB
    /// Captions, inactive titles. At least 4.5:1 on every fill.
    public var textSecondary: ThemeRGB
    /// Hints and placeholders. At least 3:1 on every fill.
    public var textTertiary: ThemeRGB

    // Fills (translucent foreground over the surface)
    /// Under the pointer.
    public var hoverFill: ThemeRGB
    /// The selected row or tab.
    public var selectionFill: ThemeRGB
    /// Multi-selected rows that are not the active one.
    public var secondarySelectionFill: ThemeRGB
    /// While pressed; text holds its contrast on it.
    public var pressedFill: ThemeRGB
    /// Behind counts and small labels.
    public var badgeFill: ThemeRGB
    /// Hairlines between sections.
    public var separator: ThemeRGB
    /// The subtle hairline around each pane.
    public var paneBorder: ThemeRGB
    /// The keyboard focus outline.
    public var focusRing: ThemeRGB
    /// Tint laid over Liquid Glass so it takes the theme's cast.
    public var glassTint: ThemeRGB
    /// Drop shadows under floating cards.
    public var shadow: ThemeRGB
    /// Selected text in chrome text fields (the terminal's selection color
    /// when the config sets one).
    public var textSelection: ThemeRGB

    // Status, from the ANSI palette
    /// Needs-attention marks (ANSI yellow).
    public var attention: ThemeRGB
    /// Errors and destructive actions (ANSI red).
    public var danger: ThemeRGB
    /// Success marks (ANSI green).
    public var success: ThemeRGB
    /// The one action color (the composer's Send): the theme's ANSI blue,
    /// at least 3:1 on the background.
    public var highlight: ThemeRGB
    /// Glyphs and labels on `highlight`, at least 4.5:1: the opaque
    /// background or foreground, whichever contrasts more, else black or white.
    public var highlightText: ThemeRGB
    /// ANSI 0...15.
    public var ansi: [ThemeRGB]

    /// `background-opacity`, 0...1; the surfaces carry it as their alpha.
    public var backgroundOpacity: Double
    /// `background-blur` as Ghostty encodes it (0 off, >0 radius, <0 macOS glass).
    public var backgroundBlur: Int

    /// Theme-derived tint opacity used when a wallpaper is selected.
    ///
    /// Dark themes keep a denser tint for readable text; lighter and higher
    /// contrast themes can reveal more of the wallpaper without losing legibility.
    public var wallpaperTintOpacity: Double {
        let contrastHeadroom = min(max((textPrimary.contrast(with: windowBackground) - Self.minimumTextContrast) / 8, 0), 1)
        let luminanceBias = min(max((windowBackground.relativeLuminance - 0.18) * 0.12, -0.03), 0.08)
        let themeFloor = isDark ? 0.62 : 0.56
        return min(max(themeFloor + (1 - contrastHeadroom) * 0.10 + luminanceBias, 0.52), 0.76)
    }

    /// Minimum contrast for primary and secondary chrome text.
    public static let minimumTextContrast = 4.5
    /// Minimum contrast for tertiary text and status marks.
    public static let minimumMarkContrast = 3.0

    /// Ghostty's default theme's tokens, used until the config is read.
    public static let fallback = derive(from: .ghosttyDefault)

    /// Every chrome color for a terminal theme.
    ///
    /// ```swift
    /// let tokens = ThemeTokens.derive(from: ThemeInput(terminalTheme: .monokai))
    /// ```
    ///
    /// - Parameter input: The terminal theme.
    /// - Returns: The tokens, with every text tier holding its contrast.
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
        let highlight = status(4)
        func best(_ candidates: [ThemeRGB]) -> ThemeRGB {
            candidates.max { $0.contrast(with: highlight) < $1.contrast(with: highlight) }!
        }
        // A theme color when one reads on the blue; black or white always reaches 4.5:1.
        let themed = best([bg.withAlpha(1), primary.withAlpha(1)])
        let highlightText = themed.contrast(with: highlight) >= minimumTextContrast
            ? themed
            : best([ThemeRGB(hex: 0x000000), ThemeRGB(hex: 0xFFFFFF)])
        return ThemeTokens(
            isDark: isDark,
            windowBackground: surface,
            sidebarBackground: surface,
            contentBackground: surface,
            chromeBackground: bg.mixed(toward: fg, isDark ? 0.05 : 0.035),
            elevatedBackground: bg.mixed(toward: fg, isDark ? 0.07 : 0.02),
            stripBackground: bg.mixed(toward: .black, isDark ? 0.22 : 0.05).withAlpha(input.backgroundOpacity),
            sidebarStep: fg.withAlpha(0.04),
            stripStep: ThemeRGB.black.withAlpha(isDark ? 0.22 : 0.05),
            textPrimary: primary,
            textSecondary: secondary,
            textTertiary: tertiary,
            hoverFill: hover,
            selectionFill: selection,
            secondarySelectionFill: fg.withAlpha(isDark ? 0.07 : 0.055),
            pressedFill: pressed,
            badgeFill: fg.withAlpha(isDark ? 0.14 : 0.10),
            separator: fg.withAlpha(isDark ? 0.08 : 0.07),
            paneBorder: fg.withAlpha(isDark ? 0.07 : 0.09),
            focusRing: fg.withAlpha(0.40),
            glassTint: bg.withAlpha(isDark ? 0.40 : 0.30),
            shadow: bg.mixed(toward: .black, 0.85),
            textSelection: input.selectionBackground ?? bg.mixed(toward: fg, 0.22),
            attention: status(3),
            danger: status(1),
            success: status(2),
            highlight: highlight,
            highlightText: highlightText,
            ansi: palette,
            backgroundOpacity: input.backgroundOpacity,
            backgroundBlur: input.backgroundBlur
        )
    }

    /// `color`, pushed away from `surface` (toward white or black) until it
    /// reaches `minimum` contrast.
    public static func readable(_ color: ThemeRGB, over surface: ThemeRGB, minimum: Double) -> ThemeRGB {
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
