import AppKit
import CmuxFoundation
import CmuxPanes

struct AgentSessionWebTheme: Equatable {
    let isDark: Bool
    let pageBackground: String
    let surfaceBackground: String
    let surfaceElevatedBackground: String
    let inputBackground: String
    let border: String
    let borderStrong: String
    let text: String
    let mutedText: String
    let softText: String
    let accent: String
    let accentSoft: String
    let danger: String
    let shadow: String

    var dictionary: [String: Any] {
        [
            "isDark": isDark,
            "pageBackground": pageBackground,
            "surfaceBackground": surfaceBackground,
            "surfaceElevatedBackground": surfaceElevatedBackground,
            "inputBackground": inputBackground,
            "border": border,
            "borderStrong": borderStrong,
            "text": text,
            "mutedText": mutedText,
            "softText": softText,
            "accent": accent,
            "accentSoft": accentSoft,
            "danger": danger,
            "shadow": shadow
        ]
    }

    static func resolve(appearance: PanelAppearance) -> AgentSessionWebTheme {
        let base = appearance.backgroundColor.markdownOpaqueSRGB
        let isDark = !base.isLightColor
        let overlay: NSColor = isDark ? .white : .black
        let inverseOverlay: NSColor = isDark ? .black : .white
        let contentBackground = appearance.contentBackgroundColor
        let transparentContent = contentBackground.alphaComponent < 0.001
        let baseSurfaceAlpha: CGFloat = appearance.drawsContentBackground ? 0.72 : 0.34
        let elevatedSurfaceAlpha: CGFloat = appearance.drawsContentBackground ? 0.84 : 0.48
        let inputAlpha: CGFloat = appearance.drawsContentBackground ? 0.60 : 0.36
        let border = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.62 : 1.34,
            of: overlay
        )
        let borderStrong = base.markdownThemeOverlay(
            targetContrast: isDark ? 2.12 : 1.64,
            of: overlay
        )
        let surface = base
            .blended(withFraction: isDark ? 0.05 : 0.03, of: overlay)?
            .withAlphaComponent(baseSurfaceAlpha)
            ?? base.withAlphaComponent(baseSurfaceAlpha)
        let surfaceElevated = base
            .blended(withFraction: isDark ? 0.08 : 0.05, of: overlay)?
            .withAlphaComponent(elevatedSurfaceAlpha)
            ?? base.withAlphaComponent(elevatedSurfaceAlpha)
        let input = base
            .blended(withFraction: isDark ? 0.18 : 0.10, of: inverseOverlay)?
            .withAlphaComponent(inputAlpha)
            ?? base.withAlphaComponent(inputAlpha)
        let foreground = appearance.foregroundColor
        let accent = cmuxAccentNSColor()
        let danger = (NSColor(hex: isDark ? "#FF8D7E" : "#B3261E") ?? .systemRed)
        return AgentSessionWebTheme(
            isDark: isDark,
            pageBackground: transparentContent ? "transparent" : contentBackground.markdownCSSColor,
            surfaceBackground: surface.markdownCSSColor,
            surfaceElevatedBackground: surfaceElevated.markdownCSSColor,
            inputBackground: input.markdownCSSColor,
            border: border.withAlphaComponent(border.alphaComponent * 0.72).markdownCSSColor,
            borderStrong: borderStrong.markdownCSSColor,
            text: foreground.markdownCSSColor,
            mutedText: foreground.withAlphaComponent(0.58).markdownCSSColor,
            softText: foreground.withAlphaComponent(0.78).markdownCSSColor,
            accent: accent.markdownCSSColor,
            accentSoft: accent.withAlphaComponent(isDark ? 0.20 : 0.16).markdownCSSColor,
            danger: danger.markdownCSSColor,
            shadow: isDark ? "rgba(0, 0, 0, 0.20)" : "rgba(0, 0, 0, 0.10)"
        )
    }
}
