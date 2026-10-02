import CoreGraphics

/// One color as sRGB components, so it can cross to raster threads.
nonisolated struct RGBA: Hashable, Sendable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    func with(alpha: CGFloat) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// The transcript's colors, resolved from `Palette` inside the view's theme
/// scope on the main actor (`TranscriptColors.resolve`) and passed by value to
/// background rasterization. Part of every raster's cache key, so a theme
/// change redraws. No blue: outgoing bubbles invert the theme (foreground fill,
/// background text); incoming are the foreground at low alpha.
nonisolated struct TranscriptColors: Hashable, Sendable {
    var background: RGBA
    var textPrimary: RGBA
    var textSecondary: RGBA
    var textTertiary: RGBA
    var incomingFill: RGBA
    var outgoingFill: RGBA
    var outgoingText: RGBA
    var cardFill: RGBA
    var cardStroke: RGBA
    var badgeFill: RGBA
    var badgeStroke: RGBA
    var danger: RGBA
    var success: RGBA
    var attention: RGBA

    /// Neutral grays for tests and for code that runs before a view has a scope.
    static let neutralDark = TranscriptColors(
        background: RGBA(r: 0.1, g: 0.1, b: 0.1, a: 1), textPrimary: RGBA(r: 0.92, g: 0.92, b: 0.92, a: 1),
        textSecondary: RGBA(r: 0.66, g: 0.66, b: 0.66, a: 1), textTertiary: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1),
        incomingFill: RGBA(r: 0.92, g: 0.92, b: 0.92, a: 0.12), outgoingFill: RGBA(r: 0.92, g: 0.92, b: 0.92, a: 1),
        outgoingText: RGBA(r: 0.1, g: 0.1, b: 0.1, a: 1), cardFill: RGBA(r: 0.92, g: 0.92, b: 0.92, a: 0.06),
        cardStroke: RGBA(r: 0.92, g: 0.92, b: 0.92, a: 0.14), badgeFill: RGBA(r: 0.18, g: 0.18, b: 0.18, a: 1),
        badgeStroke: RGBA(r: 0.1, g: 0.1, b: 0.1, a: 1), danger: RGBA(r: 0.9, g: 0.3, b: 0.3, a: 1),
        success: RGBA(r: 0.4, g: 0.8, b: 0.4, a: 1), attention: RGBA(r: 0.9, g: 0.75, b: 0.3, a: 1))
}
