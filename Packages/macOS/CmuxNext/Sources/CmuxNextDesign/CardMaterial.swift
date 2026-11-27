public import CmuxTheme
public import Foundation
public import CmuxNextDesignTokens

/// The card fill a floating surface may lay on its glass (`makeOverlayPanel(cardFill:
/// true)`; the web pages' `--cmux-card-tint`). No native overlay uses it since Leo
/// 2026-10-21 ("STOP DOING SOLID. WE HAVE GLASS, SO JUST USE GLASS."): overlays
/// are the shared glass alone. As a fill it is:
/// the opaque popup surface laid on the glass or blur at `opacity`, with a
/// visible rim.
///
/// Lawrence, 2026-10-20: "The card is potentially too liquid glassy so it is
/// very hard to see and use." The themed glass tint alone (about 0.4 alpha)
/// let a busy wallpaper or a bright page through the text. A card is now
/// mostly opaque: the glass shows only at its refracting edge and faintly
/// through the fill. `opacity` is the least alpha, from `minimumOpacity` up,
/// at which both the primary and the secondary text keep WCAG AA (4.5:1) over
/// the fill laid on pure black and on pure white, the worst a blurred
/// backdrop can do. Reduce Transparency draws the fill at alpha 1 instead
/// (`OverlayMaterial.opaque`).
///
/// ```swift
/// let card = CardMaterial(tokens, lift: ChromeTunables.opaqueOverlayLift.value,
///                         minimumOpacity: ChromeTunables.cardOpacity.value)
/// fillLayer.backgroundColor = card.tint.nsColor.cgColor
/// ```
public nonisolated struct CardMaterial: Hashable, Sendable {
    /// The default least opacity (`glass.cardOpacity`): mostly opaque, so the
    /// glass reads as an edge, not as the card's background.
    public static let defaultMinimumOpacity: Double = 0.9

    /// The opaque popup surface (`ThemeTokens/opaqueOverlayFill(lift:)`).
    public let fill: ThemeRGB
    /// The alpha the fill draws at on glass or blur (1 when no lower alpha keeps AA).
    public let opacity: Double
    /// The rim: the primary text at a low alpha, clearly visible on the card and on the backdrop.
    public let rim: ThemeRGB

    /// The fill at `opacity`: what a card paints over its glass or blur.
    public var tint: ThemeRGB { fill.withAlpha(opacity) }

    /// - Parameters:
    ///   - fill: The opaque popup surface.
    ///   - inks: Every text color the card carries (primary and secondary).
    ///   - minimumOpacity: The least opacity (clamped to 0...1).
    ///   - isDark: Whether the theme is dark (a dark rim is a little denser).
    public init(fill: ThemeRGB, inks: [ThemeRGB], minimumOpacity: Double, isDark: Bool) {
        self.fill = fill.withAlpha(1)
        opacity = Self.opacity(fill: self.fill, inks: inks.map { $0.withAlpha(1) }, minimumOpacity: minimumOpacity)
        rim = (inks.first ?? fill).withAlpha(isDark ? 0.18 : 0.14)
    }

    /// The card material for a theme.
    ///
    /// - Parameters:
    ///   - tokens: The theme.
    ///   - lift: The popup surface lift (`glass.opaqueOverlayLift`).
    ///   - minimumOpacity: The least opacity (`glass.cardOpacity`).
    public init(_ tokens: ThemeTokens, lift: Double, minimumOpacity: Double = CardMaterial.defaultMinimumOpacity) {
        self.init(fill: tokens.opaqueOverlayFill(lift: lift), inks: [tokens.textPrimary, tokens.textSecondary],
                  minimumOpacity: minimumOpacity, isDark: tokens.isDark)
    }

    /// The least alpha from `minimumOpacity` (in 1% steps) at which every ink
    /// keeps 4.5:1 over `fill` laid on black and on white; 1 when none does.
    public static func opacity(fill: ThemeRGB, inks: [ThemeRGB], minimumOpacity: Double) -> Double {
        let start = Int((min(max(minimumOpacity, 0), 1) * 100).rounded())
        for percent in start..<100 {
            let alpha = Double(percent) / 100
            let tint = fill.withAlpha(alpha)
            if inks.allSatisfy({ TooltipSurface.worstContrast(ink: $0, tint: tint) >= ThemeTokens.minimumTextContrast }) {
                return alpha
            }
        }
        return 1
    }
}
