import AppKit
import CmuxFoundation
import CmuxSettings

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

    static func resolve(
        appearance: PanelAppearance,
        chromePalette: ChromePalette? = nil
    ) -> AgentSessionWebTheme {
        let base = appearance.backgroundColor.markdownOpaqueSRGB
        let isDark = chromePalette.map { $0.colorScheme == .dark } ?? !base.isLightColor
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
        var pageBackground = transparentContent ? "transparent" : contentBackground.markdownCSSColor
        var surfaceBackground = surface.markdownCSSColor
        var surfaceElevatedBackground = surfaceElevated.markdownCSSColor
        var inputBackground = input.markdownCSSColor
        var borderCSSColor = border.withAlphaComponent(border.alphaComponent * 0.72).markdownCSSColor
        var borderStrongCSSColor = borderStrong.markdownCSSColor
        var textCSSColor = foreground.markdownCSSColor
        var mutedTextCSSColor = foreground.withAlphaComponent(0.58).markdownCSSColor
        var softTextCSSColor = foreground.withAlphaComponent(0.78).markdownCSSColor
        let defaultAccent = cmuxAccentNSColor(palette: chromePalette)
        var accentCSSColor = (chromePalette.map {
            Self.nsColor(for: $0.accent)
        } ?? defaultAccent).markdownCSSColor
        var accentSoftCSSColor = (chromePalette.map {
            Self.nsColor(for: $0.accentSoft)
        } ?? defaultAccent.withAlphaComponent(isDark ? 0.20 : 0.16)).markdownCSSColor
        var dangerCSSColor = (chromePalette.map {
            Self.nsColor(for: $0[.agentError])
        } ?? (NSColor(hex: isDark ? "#FF8D7E" : "#B3261E") ?? .systemRed)).markdownCSSColor
        if let chromePalette {
            pageBackground = transparentContent ? "transparent" : Self.nsColor(for: chromePalette.surface).markdownCSSColor
            surfaceBackground = Self.nsColor(for: chromePalette.surface).markdownCSSColor
            surfaceElevatedBackground = Self.nsColor(for: chromePalette.surfaceRaised).markdownCSSColor
            inputBackground = Self.nsColor(for: chromePalette.surfaceHover).markdownCSSColor
            borderCSSColor = Self.nsColor(for: chromePalette.borderSubtle).markdownCSSColor
            borderStrongCSSColor = Self.nsColor(for: chromePalette.border).markdownCSSColor
            textCSSColor = Self.nsColor(for: chromePalette.textPrimary).markdownCSSColor
            mutedTextCSSColor = Self.nsColor(for: chromePalette.textSecondary).markdownCSSColor
            softTextCSSColor = Self.nsColor(for: chromePalette.textTertiary).markdownCSSColor
            accentCSSColor = Self.nsColor(for: chromePalette.accent).markdownCSSColor
            accentSoftCSSColor = Self.nsColor(for: chromePalette.accentSoft).markdownCSSColor
            dangerCSSColor = Self.nsColor(for: chromePalette.agentError).markdownCSSColor
        }
        return AgentSessionWebTheme(
            isDark: isDark,
            pageBackground: pageBackground,
            surfaceBackground: surfaceBackground,
            surfaceElevatedBackground: surfaceElevatedBackground,
            inputBackground: inputBackground,
            border: borderCSSColor,
            borderStrong: borderStrongCSSColor,
            text: textCSSColor,
            mutedText: mutedTextCSSColor,
            softText: softTextCSSColor,
            accent: accentCSSColor,
            accentSoft: accentSoftCSSColor,
            danger: dangerCSSColor,
            shadow: isDark ? "rgba(0, 0, 0, 0.20)" : "rgba(0, 0, 0, 0.10)"
        )
    }

    private static func nsColor(for color: ChromeColor) -> NSColor {
        NSColor(
            srgbRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
    }
}
