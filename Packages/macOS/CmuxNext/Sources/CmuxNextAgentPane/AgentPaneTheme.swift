import CmuxNextDesign
import Foundation

/// The page's theme (`window.cmuxAcpmuxBridge.applyTheme`, the TypeScript
/// `AgentSessionTheme`) derived from the Ghostty-based `ThemeTokens`, so the
/// pane matches the terminal and chrome. No blue accent (REWRITE.md visual
/// rules): the accent is the foreground and its soft form the selection fill;
/// labels on it take the background, opaque so a translucent window's
/// backdrop doesn't thin them.
enum AgentPaneTheme {
    static func values(_ tokens: ThemeTokens) -> [String: any Sendable] {
        let page = tokens.contentBackground
        var opaquePage = page
        opaquePage.alpha = 1
        return [
            "isDark": tokens.isDark,
            "pageBackground": css(page),
            "surfaceBackground": css(page),
            "surfaceElevatedBackground": css(tokens.elevatedBackground),
            // The field sits on the page, which already paints the theme's
            // color; it adds only the hover tint, so a translucent window's
            // backdrop shows through it as much as through the terminal.
            "inputBackground": css(tokens.hoverFill),
            "border": css(tokens.separator),
            "borderStrong": css(tokens.paneBorder),
            "text": css(tokens.textPrimary),
            "mutedText": css(tokens.textSecondary),
            "softText": css(tokens.textTertiary),
            "accent": css(tokens.textPrimary),
            "accentSoft": css(tokens.selectionFill),
            "accentText": css(opaquePage),
            "danger": css(tokens.danger),
            "warning": css(tokens.attention),
            "shadow": css(tokens.shadow),
        ]
    }

    /// The color WebKit shows behind and around the page: clear for a
    /// translucent theme, where it would stack under the page's own fill (as
    /// `WebKitTab` does).
    static func underPageColor(_ tokens: ThemeTokens) -> ThemeRGB {
        tokens.contentBackground.alpha < 1 ? tokens.contentBackground.withAlpha(0) : tokens.contentBackground
    }

    /// `rgba(r, g, b, a)` with 0-255 channels.
    static func css(_ color: ThemeRGB) -> String {
        func channel(_ value: Double) -> Int { Int((value * 255).rounded()) }
        let alpha = (color.alpha * 1000).rounded() / 1000
        return "rgba(\(channel(color.red)), \(channel(color.green)), \(channel(color.blue)), \(alpha))"
    }

    /// The script that applies `tokens` to a loaded page.
    static func script(_ tokens: ThemeTokens) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: values(tokens), options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "window.cmuxAcpmuxBridge?.applyTheme(\(json));"
    }
}
