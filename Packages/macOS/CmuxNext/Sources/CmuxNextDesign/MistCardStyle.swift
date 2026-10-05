import CmuxTheme
/// The material used by a local mist card.
public nonisolated enum MistCardMaterial: String, Equatable, Sendable {
    case frosted
}

/// The sampled contrast result for one local mist card.
public nonisolated struct MistContrastCheck: Equatable, Sendable {
    /// The artwork color sampled from its authored dominant palette.
    public let sampledArt: ThemeRGB
    /// The color seen behind text after the card is composited over the art.
    public let renderedSurface: ThemeRGB
    /// The text color chosen for the card.
    public let text: ThemeRGB
    /// The required WCAG AA ratio.
    public let minimum: Double
    /// The measured WCAG ratio.
    public let ratio: Double

    /// Whether the chosen text passes the WCAG AA threshold.
    public var passesAA: Bool { ratio >= minimum }
}

/// A small frosted card placed behind dense text over mist artwork.
public nonisolated struct MistCardStyle: Equatable, Sendable {
    /// The local card material, rather than a window-wide tint.
    public let material: MistCardMaterial
    /// The card's color and opacity over the sampled artwork.
    public let fill: ThemeRGB
    /// The card's text color after the contrast check.
    public let text: ThemeRGB
    /// The continuous corner radius in points.
    public let cornerRadius: Double
    /// The proof that card text remains readable over sampled art.
    public let contrastCheck: MistContrastCheck

    /// Mist cards are intentionally scoped to their dense content owner.
    public let appliesLocally = true

    /// Creates a local card style from a resolved contrast check.
    ///
    /// - Parameters:
    ///   - material: The local card material.
    ///   - fill: The card fill composited over sampled artwork.
    ///   - text: The contrast-checked card text color.
    ///   - cornerRadius: The card corner radius in points.
    ///   - contrastCheck: The sampled-art contrast evidence.
    public init(material: MistCardMaterial, fill: ThemeRGB, text: ThemeRGB,
                cornerRadius: Double, contrastCheck: MistContrastCheck) {
        self.material = material
        self.fill = fill
        self.text = text
        self.cornerRadius = cornerRadius
        self.contrastCheck = contrastCheck
    }
}
