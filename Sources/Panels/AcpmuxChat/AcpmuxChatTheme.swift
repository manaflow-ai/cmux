import AppKit
import CmuxFoundation

/// Colors and fonts for the native acpmux chat pane, derived from the Ghostty theme
/// (panel background and foreground) and the cmux accent color.
struct AcpmuxChatTheme: Equatable {
    let isDark: Bool
    let background: NSColor
    let foreground: NSColor
    let secondaryText: NSColor
    let tertiaryText: NSColor
    let accent: NSColor
    let userBubble: NSColor
    let userText: NSColor
    let assistantBubble: NSColor
    let codeBackground: NSColor
    let surface: NSColor
    let border: NSColor
    let danger: NSColor
    let success: NSColor

    let bodyFont = NSFont.systemFont(ofSize: 13.5)
    let smallFont = NSFont.systemFont(ofSize: 11.5)
    let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func resolve(appearance: PanelAppearance, accent accentColor: CmuxAccentColor) -> AcpmuxChatTheme {
        let base = appearance.backgroundColor.markdownOpaqueSRGB
        let isDark = !base.isLightColor
        let overlay: NSColor = isDark ? .white : .black
        let foreground = appearance.foregroundColor
        let accent = accentColor.nsColor(isDark: isDark)
        return AcpmuxChatTheme(
            isDark: isDark,
            background: appearance.contentBackgroundColor,
            foreground: foreground,
            secondaryText: foreground.withAlphaComponent(0.62),
            tertiaryText: foreground.withAlphaComponent(0.42),
            accent: accent,
            userBubble: accent,
            userText: accent.isLightColor ? .black : .white,
            assistantBubble: base.blended(withFraction: isDark ? 0.10 : 0.06, of: overlay) ?? base,
            codeBackground: base.blended(withFraction: isDark ? 0.16 : 0.09, of: overlay) ?? base,
            surface: base.blended(withFraction: isDark ? 0.07 : 0.035, of: overlay) ?? base,
            border: foreground.withAlphaComponent(isDark ? 0.16 : 0.12),
            danger: NSColor(hex: isDark ? "#FF8D7E" : "#B3261E") ?? .systemRed,
            success: NSColor(hex: isDark ? "#7EE2A8" : "#1E7B46") ?? .systemGreen
        )
    }
}
