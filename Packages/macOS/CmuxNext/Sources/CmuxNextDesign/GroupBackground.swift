public import CmuxTheme
public import CmuxNextDesignTokens

/// A sidebar group header's background and its ink, glass or solid (Lawrence 2026-11-05: "invariant: groups must
/// always have a visible bg color, groups should support both glassy and solid bgs too").
///
/// The invariant holds by construction: whatever the group's color (a palette color, a custom color, or none), the
/// theme, light or dark, and the style, the background as seen over the sidebar (``shown``) keeps at least
/// ``minimumVisibleContrast`` against the sidebar background. A group with no color draws a neutral fill, a step of
/// the theme's text color into the sidebar, never nothing. Glass paints a translucent ``fill`` that composites to the
/// same ``shown`` color over the theme's sidebar and lets the window's glass through, with a hairline ``rim`` that
/// stays visible over any desktop; solid paints ``shown`` itself.
///
/// The ground is the theme's sidebar background, opaque: what is behind a see-through window is not known here,
/// the same limit every text token has (`ThemeTokens.glyphInk`).
///
/// ```swift
/// let background = GroupBackground(tint: group.tint, strength: .band, glass: true, themed: false, tokens: tokens)
/// pill.backgroundColor = background.fill.nsColor.cgColor
/// name.textColor = background.ink.nsColor
/// ```
public nonisolated struct GroupBackground: Equatable, Sendable {
    /// How strongly the group's color shows.
    public enum Strength: Sendable {
        /// The header bar in the group's color (`sidebar.groupHeader` band), its ink white or near-black.
        case band
        /// A faint wash of the group's color behind a name in the theme's text color (the quieter header looks).
        case wash
    }

    /// The least WCAG contrast the background keeps against the sidebar, at rest: a fill a person can see (about
    /// #E8E8E8 on white, #2B2B2B on #1E1E1E), still calm next to the text's 4.5:1.
    public static let minimumVisibleContrast = 1.2
    /// The glass fill's opacity, raised only when the color it must show cannot be reached at it.
    public static let glassOpacity = 0.6

    /// What to paint: opaque for solid, translucent for glass.
    public let fill: ThemeRGB
    /// The background as seen over the theme's sidebar background: opaque, and the color the invariant measures.
    public let shown: ThemeRGB
    /// The one ink every glyph on the background takes.
    public let ink: ThemeRGB
    /// Glass's hairline edge; nil for solid.
    public let rim: ThemeRGB?
    /// The sidebar background the background is measured against, opaque.
    public let ground: ThemeRGB

    /// Whether this is the glass look.
    public var isGlass: Bool { rim != nil }

    /// The background for a group colored `tint` in `tokens`.
    ///
    /// - Parameters:
    ///   - tint: The group's color; ``GroupTint/none`` draws the neutral fill.
    ///   - strength: The header bar or the faint wash.
    ///   - glass: The glass look (true) or the solid one.
    ///   - themed: Palette colors come from the theme (`sidebar.groupColors` = theme).
    ///   - tokens: The theme the sidebar draws in.
    public init(tint: GroupTint, strength: Strength, glass: Bool, themed: Bool, tokens: ThemeTokens) {
        let ground = tokens.sidebarBackground.withAlpha(1)
        self.ground = ground
        let text = tokens.textPrimary.withAlpha(1)
        let color: ThemeRGB? = switch tint {
        case let .palette(token): themed ? token.themeRGB(tokens) ?? token.swatchRGB(tokens) : nil
        case let .custom(rgb): ThemeTokens.readable(rgb.withAlpha(1), over: ground, minimum: ThemeTokens.minimumMarkContrast)
        case .none: nil
        }
        let base: ThemeRGB
        var inks = ChipInks.theme
        switch (strength, tint) {
        case (.band, .none):
            base = ground.mixed(toward: text, tokens.isDark ? 0.12 : 0.07)
        case let (.band, .palette(token)) where !themed:
            base = token.headerRGB(tokens)
            inks = .onColor
        case (.band, .palette):
            // The theme's color washed into the sidebar, as `GroupTint.headerChip(themed:)` drew it.
            base = ground.mixed(toward: color ?? text, tokens.isDark ? 0.34 : 0.26)
        case (.band, .custom):
            base = color ?? text
            inks = .onColor
        case (.wash, .none):
            base = ground.mixed(toward: text, tokens.isDark ? 0.08 : 0.05)
        case let (.wash, .palette(token)):
            base = ground.mixed(toward: color ?? token.swatchRGB(tokens), tokens.isDark ? 0.14 : 0.10)
        case (.wash, .custom):
            base = ground.mixed(toward: color ?? text, tokens.isDark ? 0.14 : 0.10)
        }
        let target = Self.visible(base, over: ground)
        var shown = target
        var ink: ThemeRGB
        switch strength {
        case .band:
            (shown, ink) = tokens.chip(target, inks: inks)
            // The chip's ink step may move the bar back toward the sidebar: keep it visible, then re-fit the ink.
            if shown.contrast(with: ground) < Self.minimumVisibleContrast {
                shown = Self.visible(shown, over: ground)
                ink = tokens.glyphInk(base: shown)
            }
        case .wash:
            ink = tokens.glyphInk(base: shown)
        }
        self.shown = shown.withAlpha(1)
        self.ink = ink
        if glass {
            fill = Self.glassFill(showing: self.shown, over: ground)
            rim = text.withAlpha(tokens.isDark ? 0.16 : 0.12)
        } else {
            fill = self.shown
            rim = nil
        }
    }

    /// What to paint with `steps` (hover, drop: translucent state fills) laid over the background: opaque for solid;
    /// for glass, the translucent paint that shows the stepped color over the sidebar.
    ///
    /// - Parameter steps: State fills over the background, bottom first.
    /// - Returns: The color to paint.
    public func painted(over steps: [ThemeRGB]) -> ThemeRGB {
        guard !steps.isEmpty else { return fill }
        let stepped = steps.reduce(shown) { $1.composited(over: $0) }
        return isGlass ? Self.glassFill(showing: stepped, over: ground) : stepped
    }

    /// `color`, pushed away from `ground` (toward white or black) until it keeps ``minimumVisibleContrast``.
    static func visible(_ color: ThemeRGB, over ground: ThemeRGB) -> ThemeRGB {
        let opaque = color.withAlpha(1)
        guard opaque.contrast(with: ground) < minimumVisibleContrast else { return opaque }
        let pole: ThemeRGB = ground.relativeLuminance < 0.18 ? .white : .black
        var step = 0.0
        var candidate = opaque
        while step < 1, candidate.contrast(with: ground) < minimumVisibleContrast {
            step += 0.02
            candidate = opaque.mixed(toward: pole, step)
        }
        return candidate
    }

    /// The translucent paint that composites to `shown` over `ground`: ``glassOpacity``, or the least opacity above it
    /// whose color stays in gamut.
    static func glassFill(showing shown: ThemeRGB, over ground: ThemeRGB) -> ThemeRGB {
        let pairs = [(shown.red, ground.red), (shown.green, ground.green), (shown.blue, ground.blue)]
        // Each channel g + (s - g) / a must stay in 0...1: a >= (s - g) / (1 - g) going up, (g - s) / g going down.
        let needed = pairs.map { s, g -> Double in
            if s > g { return g < 1 ? (s - g) / (1 - g) : 1 }
            if s < g { return g > 0 ? (g - s) / g : 1 }
            return 0
        }.max() ?? 0
        let alpha = min(1, max(glassOpacity, needed))
        func channel(_ s: Double, _ g: Double) -> Double { min(1, max(0, g + (s - g) / alpha)) }
        return ThemeRGB(red: channel(shown.red, ground.red), green: channel(shown.green, ground.green),
                        blue: channel(shown.blue, ground.blue), alpha: alpha)
    }
}
