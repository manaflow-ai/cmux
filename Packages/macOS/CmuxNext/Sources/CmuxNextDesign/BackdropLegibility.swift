public import CmuxTheme

/// The glass that keeps text and controls readable over backdrop art (cx-t2x): the least opacity
/// of the theme's own surface color, laid over the art, at which every text role keeps its WCAG
/// contrast whatever the art underneath is. The window's tint never goes below it, so no art and
/// no opacity setting can make text unreadable; above it the user's choice shows more or less art.
public nonisolated enum BackdropLegibility {
    /// Primary and secondary text (WCAG AA body text).
    public static let textContrast = ThemeTokens.minimumTextContrast
    /// Tertiary text and status marks.
    public static let markContrast = ThemeTokens.minimumMarkContrast

    /// The darkest and lightest the art can be. Unmeasured art is anything from black to white.
    public struct ArtRange: Sendable, Equatable {
        public var darkest: ThemeRGB
        public var lightest: ThemeRGB

        public init(darkest: ThemeRGB, lightest: ThemeRGB) {
            self.darkest = darkest
            self.lightest = lightest
        }

        public static let any = ArtRange(darkest: ThemeRGB(red: 0, green: 0, blue: 0),
                                         lightest: ThemeRGB(red: 1, green: 1, blue: 1))
    }

    /// The least opacity at or above `requested` at which `scrim` over every extreme of `art`
    /// gives each text color at least its contrast. 1 when even the opaque scrim falls short
    /// (a theme whose own text fails): the art then hides, rather than making it worse.
    ///
    /// - Parameters:
    ///   - texts: Each text color with the contrast it needs.
    ///   - scrim: The glass color, the theme's surface background.
    ///   - art: The art's extremes.
    ///   - requested: The opacity the user or theme asked for.
    /// - Returns: The opacity, `requested`...1, in steps of 0.01.
    public static func scrimOpacity(texts: [(color: ThemeRGB, contrast: Double)], scrim: ThemeRGB,
                                    art: ArtRange = .any, requested: Double) -> Double {
        let start = Int((min(max(requested.isFinite ? requested : 1, 0), 1) * 100).rounded(.up))
        for step in start...100 {
            let opacity = Double(step) / 100
            if isLegible(texts: texts, scrim: scrim, art: art, opacity: opacity) { return opacity }
        }
        return 1
    }

    /// Whether every text color keeps its contrast on `scrim` at `opacity` over both art extremes.
    public static func isLegible(texts: [(color: ThemeRGB, contrast: Double)], scrim: ThemeRGB,
                                 art: ArtRange = .any, opacity: Double) -> Bool {
        let glass = scrim.withAlpha(opacity)
        return [art.darkest, art.lightest].allSatisfy { extreme in
            let seen = glass.composited(over: extreme)
            return texts.allSatisfy { $0.color.withAlpha(1).contrast(with: seen) >= $0.contrast }
        }
    }

    /// The text roles of `tokens` with the contrast each needs.
    public static func texts(of tokens: ThemeTokens) -> [(color: ThemeRGB, contrast: Double)] {
        [(tokens.textPrimary, textContrast), (tokens.textSecondary, textContrast), (tokens.textTertiary, markContrast)]
    }

    /// The least window tint over art for `tokens`, at or above `requested`.
    public static func tintOpacity(_ tokens: ThemeTokens, requested: Double, art: ArtRange = .any) -> Double {
        scrimOpacity(texts: texts(of: tokens), scrim: tokens.surfaceBackground.withAlpha(1), art: art, requested: requested)
    }
}
