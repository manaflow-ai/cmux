import AppKit
import CmuxNextDesign

extension TranscriptColors {
    /// Resolves every token from `Palette`. Callers run it inside
    /// `performWithTheme` (theme-scoped).
    static func resolveInScope() -> TranscriptColors { // theme-scoped
        let foreground = rgba(Palette.textPrimary)
        let background = rgba(Palette.windowBackground).with(alpha: 1)
        return TranscriptColors(
            background: background,
            textPrimary: foreground,
            textSecondary: rgba(Palette.textSecondary),
            textTertiary: rgba(Palette.textTertiary),
            incomingFill: foreground.with(alpha: 0.11),
            outgoingFill: foreground.with(alpha: 1),
            outgoingText: rgba(Palette.textOnPrimary).with(alpha: 1),
            cardFill: foreground.with(alpha: 0.05),
            cardStroke: rgba(Palette.separator),
            badgeFill: rgba(Palette.elevatedBackground).with(alpha: 1),
            badgeStroke: background,
            danger: rgba(Palette.danger),
            success: rgba(Palette.success),
            attention: rgba(Palette.attention))
    }

    private static func rgba(_ color: NSColor) -> RGBA {
        let c = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        return RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
}
