public import CmuxTheme

/// The darkest and lightest the art behind the window's glass can be, and the glass that keeps
/// text and controls readable over it (cx-t2x): the least opacity of the theme's own surface
/// color, laid over the art, at which every text role keeps its WCAG contrast whatever the art
/// underneath is. The window's tint never goes below it, so no art and no opacity setting can
/// make text unreadable; above it the user's choice shows more or less art.
public nonisolated struct BackdropArtRange: Sendable, Equatable {
    public var darkest: ThemeRGB
    public var lightest: ThemeRGB

    public init(darkest: ThemeRGB, lightest: ThemeRGB) {
        self.darkest = darkest
        self.lightest = lightest
    }

    /// Unmeasured art: anything from black to white.
    public static let any = BackdropArtRange(darkest: ThemeRGB(red: 0, green: 0, blue: 0),
                                             lightest: ThemeRGB(red: 1, green: 1, blue: 1))

    /// The least opacity at or above `requested` at which `scrim` over both extremes gives each
    /// text color at least its contrast. 1 when even the opaque scrim falls short (a theme whose
    /// own text fails): the art then hides, rather than making it worse.
    ///
    /// - Parameters:
    ///   - texts: Each text color with the contrast it needs.
    ///   - scrim: The glass color, the theme's surface background.
    ///   - requested: The opacity the user or theme asked for.
    /// - Returns: The opacity, `requested`...1, in steps of 0.01.
    public func scrimOpacity(texts: [(color: ThemeRGB, contrast: Double)], scrim: ThemeRGB, requested: Double) -> Double {
        let start = Int((min(max(requested.isFinite ? requested : 1, 0), 1) * 100).rounded(.up))
        for step in start...100 {
            let opacity = Double(step) / 100
            if isLegible(texts: texts, scrim: scrim, opacity: opacity) { return opacity }
        }
        return 1
    }

    /// Whether every text color keeps its contrast on `scrim` at `opacity` over both extremes.
    public func isLegible(texts: [(color: ThemeRGB, contrast: Double)], scrim: ThemeRGB, opacity: Double) -> Bool {
        let glass = scrim.withAlpha(opacity)
        return [darkest, lightest].allSatisfy { extreme in
            let seen = glass.composited(over: extreme)
            return texts.allSatisfy { $0.color.withAlpha(1).contrast(with: seen) >= $0.contrast }
        }
    }
}

public nonisolated extension ThemeTokens {
    /// The text roles with the contrast each needs over art: primary and secondary text at WCAG
    /// AA body contrast, tertiary text and status marks at the mark contrast.
    var backdropTexts: [(color: ThemeRGB, contrast: Double)] {
        [(textPrimary, Self.minimumTextContrast), (textSecondary, Self.minimumTextContrast),
         (textTertiary, Self.minimumMarkContrast)]
    }

    /// The least window tint over `art`, at or above `requested`, that keeps ``backdropTexts``
    /// legible on the surface color.
    func legibleTintOpacity(over art: BackdropArtRange = .any, requested: Double) -> Double {
        art.scrimOpacity(texts: backdropTexts, scrim: surfaceBackground.withAlpha(1), requested: requested)
    }
}
