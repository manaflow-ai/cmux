import CmuxTheme
/// The resolved art-aware treatment for a window in mist mode.
public nonisolated struct MistBackdropPlan: Equatable, Sendable {
    /// WCAG AA's minimum contrast ratio for primary card text.
    public static let minimumTextContrast = ThemeTokens.minimumTextContrast

    /// The gradient scrim from artwork into the theme surface.
    public let gradient: MistGradient
    /// The local frosted card treatment used by dense content surfaces.
    public let cards: MistCardStyle
    /// The dominant artwork sample used by the contrast check.
    public let sampledArt: ThemeRGB

    /// Resolves mist mode from the theme and authored artwork metadata.
    ///
    /// - Parameters:
    ///   - tokens: The active terminal theme tokens.
    ///   - metadata: The selected artwork's authored layout and palette hints.
    ///   - minimumTextContrast: The minimum ratio required for card text.
    public init(tokens: ThemeTokens, metadata: BackdropArtMetadata,
                minimumTextContrast: Double = MistBackdropPlan.minimumTextContrast) {
        let sampled = Self.sample(metadata: metadata, fallback: tokens.windowBackground.withAlpha(1))
        sampledArt = sampled

        let surface = tokens.windowBackground.withAlpha(1)
        let quietStart = min(max(metadata.quietZone.y, 0), 1)
        let quietHeight = min(max(metadata.quietZone.height, 0), 1 - quietStart)
        let fadeStart = max(0.2, quietStart - max(quietHeight * 0.6, 0.08))
        let fadeEnd = min(1, max(fadeStart + 0.18, quietStart + quietHeight * 0.75))
        gradient = MistGradient(stops: [
            MistGradientStop(location: 0, color: surface.withAlpha(0)),
            MistGradientStop(location: fadeStart, color: surface.withAlpha(0.16)),
            MistGradientStop(location: fadeEnd, color: surface.withAlpha(0.78)),
            MistGradientStop(location: 1, color: surface.withAlpha(0.96)),
        ])

        let cardBase = tokens.elevatedBackground.withAlpha(1)
        let alpha = Self.cardAlpha(text: tokens.textPrimary, base: cardBase,
                                   sampledArt: sampled, minimum: minimumTextContrast)
        let fill = cardBase.withAlpha(alpha)
        let renderedSurface = fill.composited(over: sampled)
        let text = ThemeTokens.readable(tokens.textPrimary, over: renderedSurface,
                                        minimum: minimumTextContrast)
        let check = MistContrastCheck(sampledArt: sampled, renderedSurface: renderedSurface,
                                      text: text, minimum: minimumTextContrast,
                                      ratio: text.contrast(with: renderedSurface))
        cards = MistCardStyle(material: .frosted, fill: fill, text: text,
                              cornerRadius: 12, contrastCheck: check)
    }

    private static func sample(metadata: BackdropArtMetadata, fallback: ThemeRGB) -> ThemeRGB {
        guard !metadata.dominantPalette.isEmpty else { return fallback }
        let count = Double(metadata.dominantPalette.count)
        let red = metadata.dominantPalette.reduce(0.0) { $0 + Double($1.red) } / count / 255
        let green = metadata.dominantPalette.reduce(0.0) { $0 + Double($1.green) } / count / 255
        let blue = metadata.dominantPalette.reduce(0.0) { $0 + Double($1.blue) } / count / 255
        return ThemeRGB(red: red, green: green, blue: blue)
    }

    private static func cardAlpha(text: ThemeRGB, base: ThemeRGB,
                                  sampledArt: ThemeRGB, minimum: Double) -> Double {
        // Keep the card translucent when the authored art already has enough
        // quiet contrast; increase the veil only when the sampled art needs it.
        for alpha in stride(from: 0.18, through: 0.96, by: 0.04) {
            let surface = base.withAlpha(alpha).composited(over: sampledArt)
            let readable = ThemeTokens.readable(text, over: surface, minimum: minimum)
            if readable.contrast(with: surface) >= minimum { return alpha }
        }
        return 0.96
    }
}
