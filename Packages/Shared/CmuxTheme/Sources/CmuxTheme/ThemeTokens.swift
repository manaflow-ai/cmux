import Foundation

/// Every chrome color, derived from the terminal theme (`ThemeInput`).
///
/// Surfaces that sit next to the terminal (window, sidebar, tab strip) are
/// the terminal background itself, so there is no seam. Fills are the
/// foreground at a low alpha, so they read as a slightly lighter (dark
/// themes) or darker (light themes) version of the same surface. Text is
/// the foreground, muted toward the background only as far as WCAG contrast
/// allows. No accent hue by default: blue appears only if the theme's own
/// colors are blue, and the status colors come from the theme's ANSI palette.
/// With a ``ThemeAccent`` (`appearance.accent`), selection, the focus ring and
/// `highlight` take the app theme's accent, the theme's own hue.
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
    /// Every pane's tab strip: the same ground as the window. Focus and
    /// selection fills provide hierarchy without introducing a second
    /// background token.
    public var stripBackground: ThemeRGB
    /// The sidebar's tonal step: a translucent layer over the window's one
    /// backdrop (the solid background, or the material and its tint), the
    /// foreground at the same 4% the agent pane's sidebar uses.
    public var sidebarStep: ThemeRGB
    /// Reserved for the sidebar rules; tab strips do not add a tonal step.
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
    /// The config's own selection color (`selection-background`); nil when it names none or
    /// the primary text would not read on it (an inverse-video selection).
    public var terminalSelection: ThemeRGB?
    /// Text carets: the terminal's cursor color when the config names one, else the primary
    /// text, at least 3:1 on the background.
    public var caret: ThemeRGB

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
    /// Selected and active marks (unread dots, the user's messages, Send in the agent pane):
    /// the primary text by default (no hue), the app theme's accent with `appearance.accent`.
    public var accent: ThemeRGB
    /// Glyphs and labels on `accent`, opaque: the background by default, the app theme's
    /// `onAccent` (at least 4.5:1) with an accent.
    public var onAccent: ThemeRGB
    /// The theme names its own ANSI palette, so `highlight` is the theme's
    /// accent; false when it fell back to Ghostty's default palette.
    public var hasThemeAccent: Bool
    /// ANSI 0...15.
    public var ansi: [ThemeRGB]

    /// `background-opacity`, 0...1; the surfaces carry it as their alpha.
    public var backgroundOpacity: Double
    /// `background-blur` as Ghostty encodes it (0 off, >0 radius, <0 macOS glass).
    public var backgroundBlur: Int
    /// The app theme of the same colors (``AppTheme``): surfaces, text, accent and status colors
    /// that meet the WCAG contract. Web pages get it as `--cmux-app-*` (`WebTheme`); an app theme
    /// apart from the terminal's (`appearance.appTheme`) replaces it there.
    public var app: AppTheme

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
        let app = AppTheme.derive(from: input)
        // The app accent when the setting or the theme names one; nil keeps the neutral fills.
        let accent = input.accent == .neutral && input.accentColor == nil ? nil : app[.accent]

        let hover = fg.withAlpha(isDark ? 0.06 : 0.05)
        // An accent selection is the app theme's (`AppTheme` .selection: the accent over the background).
        let selection = accent?.withAlpha(isDark ? 0.26 : 0.16) ?? fg.withAlpha(isDark ? 0.10 : 0.08)
        // The other rows of a multi-selection: the selection's own color at 0.7 of its weight, so an accent
        // theme's drag-selected rows read as one selection, as the neutral fills always did.
        let secondarySelection = accent?.withAlpha(isDark ? 0.18 : 0.11) ?? fg.withAlpha(isDark ? 0.07 : 0.055)
        let pressed = fg.withAlpha(isDark ? 0.14 : 0.11)
        // Text must hold its contrast on the strongest fill it can sit on.
        let worstSurface = [pressed, selection].map { $0.composited(over: bg) }
            .min { fg.contrast(with: $0) < fg.contrast(with: $1) }!
        // In a see-through window the quieter inks also hold over the tint on the worst desktop for
        // the theme (sidebar sweep 2026-10-21); the tint stays the opacity asked for (#22566).
        let seeThrough = seeThroughSurfaces(bg: bg, opacity: input.backgroundOpacity, isDark: isDark, fills: [pressed, selection])
        let (primary, secondary, tertiary) = inks(fg, rows: [worstSurface, bg], seeThrough: seeThrough, background: bg)

        // The config's selection fill, when text reads on it. Many themes select by inverse video
        // (the foreground as the fill, with a dark `selection-foreground`); chrome and pages draw
        // only the fill, which would hide the text, so those keep the derived selection.
        let configSelection = input.selectionBackground.flatMap {
            primary.contrast(with: $0.composited(over: bg)) >= minimumMarkContrast ? $0 : nil
        }

        let palette = input.palette.count >= 8 ? input.palette : ThemeInput.ghosttyDefault.palette
        func status(_ index: Int) -> ThemeRGB { readable(palette[index], over: bg, minimum: minimumMarkContrast) }

        let surface = bg.withAlpha(input.backgroundOpacity)
        let highlight = accent ?? status(4)
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
            stripBackground: surface,
            sidebarStep: fg.withAlpha(0.04),
            // design-tokens.json theme.stripStep. Strips paint stripBackground (the window ground), not
            // this step; the sidebar's space marks soften toward it (ProfileBarView.markColor).
            stripStep: ThemeRGB.black.withAlpha(isDark ? 0.22 : 0.05),
            textPrimary: primary,
            textSecondary: secondary,
            textTertiary: tertiary,
            hoverFill: hover,
            selectionFill: selection,
            secondarySelectionFill: secondarySelection,
            pressedFill: pressed,
            badgeFill: fg.withAlpha(isDark ? 0.14 : 0.10),
            separator: fg.withAlpha(isDark ? 0.08 : 0.07),
            paneBorder: fg.withAlpha(isDark ? 0.07 : 0.09),
            focusRing: accent ?? fg.withAlpha(0.40),
            glassTint: bg.withAlpha(isDark ? 0.40 : 0.30),
            shadow: bg.mixed(toward: .black, 0.85),
            textSelection: configSelection ?? bg.mixed(toward: fg, 0.22),
            terminalSelection: configSelection,
            caret: input.cursor.map { readable($0, over: bg, minimum: minimumMarkContrast) } ?? primary,
            attention: status(3),
            danger: status(1),
            success: status(2),
            highlight: highlight,
            highlightText: highlightText,
            accent: accent ?? primary,
            onAccent: accent == nil ? bg.withAlpha(1) : app[.onAccent],
            hasThemeAccent: input.palette.count >= 8,
            ansi: palette,
            backgroundOpacity: input.backgroundOpacity,
            backgroundBlur: input.backgroundBlur,
            app: app
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

    /// The primary, secondary and tertiary text for `foreground`, read on every surface in `rows`
    /// (the strongest row fill and the bare background). A foreground that already reads keeps
    /// its color. Otherwise it is walked toward white and toward black, and the candidate whose
    /// primary and secondary keep the higher least contrast over `rows` wins (capped at 4.5:1, so
    /// of two candidates that both read, the one toward the pole that reads better on the row
    /// fill wins). Hot Dog Stand's white on red reaches only 4.20:1, so it takes the dark ink;
    /// Grass's dark ink drops to 3.73:1 on its background, so it takes white.
    static func inks(_ foreground: ThemeRGB, rows: [ThemeRGB], seeThrough: [ThemeRGB], background bg: ThemeRGB)
        -> (ThemeRGB, ThemeRGB, ThemeRGB) {
        func least(_ ink: ThemeRGB) -> Double { rows.map { ink.contrast(with: $0) }.min() ?? 1 }
        let poles = [ThemeRGB.white, .black].sorted { $0.contrast(with: rows[0]) > $1.contrast(with: rows[0]) }
        let candidates = poles.map { pole -> (inks: (ThemeRGB, ThemeRGB, ThemeRGB), score: Double) in
            let primary = readable(foreground, over: rows, toward: pole, minimum: minimumTextContrast)
            let inkSurface = (rows + seeThrough).min { primary.contrast(with: $0) < primary.contrast(with: $1) } ?? bg
            let secondary = muted(primary, toward: bg, upTo: 0.38, over: inkSurface, minimum: minimumTextContrast)
            let tertiary = muted(primary, toward: bg, upTo: 0.55, over: inkSurface, minimum: minimumMarkContrast)
            return ((primary, secondary, tertiary), min(least(primary), least(secondary), minimumTextContrast))
        }
        var chosen = candidates[0]
        for candidate in candidates.dropFirst() where candidate.score > chosen.score { chosen = candidate }
        return chosen.inks
    }

    /// `color` walked toward `pole` until it reaches `minimum` contrast over every surface (or `pole`).
    static func readable(_ color: ThemeRGB, over surfaces: [ThemeRGB], toward pole: ThemeRGB, minimum: Double) -> ThemeRGB {
        func reads(_ ink: ThemeRGB) -> Bool { surfaces.allSatisfy { ink.contrast(with: $0) >= minimum } }
        var step = 0.0
        var candidate = color
        while step < 1, !reads(candidate) {
            step += 0.02
            candidate = color.mixed(toward: pole, step)
        }
        return candidate
    }

    /// What text sits on in a window of `opacity` below 1: the background at that opacity over
    /// the worst desktop for the theme (black behind a light theme, white behind a dark one),
    /// alone and under each of `fills`. Empty for an opaque window.
    static func seeThroughSurfaces(bg: ThemeRGB, opacity: Double, isDark: Bool, fills: [ThemeRGB]) -> [ThemeRGB] {
        guard opacity < 1 else { return [] }
        let tint = bg.withAlpha(opacity).composited(over: isDark ? .white : .black)
        return [tint] + fills.map { $0.composited(over: tint) }
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
