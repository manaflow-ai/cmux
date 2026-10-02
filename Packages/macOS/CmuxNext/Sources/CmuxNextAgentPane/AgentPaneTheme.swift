import CmuxNextDesign
import Foundation

/// The page's theme (`window.cmuxAcpmuxBridge.applyTheme`, the TypeScript
/// `AgentSessionTheme`) derived from the Ghostty-based `ThemeTokens`, so the
/// pane matches the terminal and chrome. No blue accent (REWRITE.md visual
/// rules): the accent is the foreground and its soft form the selection fill.
enum AgentPaneTheme {
    static func values(_ tokens: ThemeTokens) -> [String: any Sendable] {
        let page = tokens.contentBackground
        return [
            "isDark": tokens.isDark,
            "pageBackground": css(page),
            "surfaceBackground": css(page),
            "surfaceElevatedBackground": css(tokens.elevatedBackground),
            "inputBackground": css(tokens.hoverFill.composited(over: page)),
            "border": css(tokens.separator),
            "borderStrong": css(tokens.paneBorder),
            "text": css(tokens.textPrimary),
            "mutedText": css(tokens.textSecondary),
            "softText": css(tokens.textTertiary),
            "accent": css(tokens.textPrimary),
            "accentSoft": css(tokens.selectionFill),
            "danger": css(tokens.danger),
            "shadow": css(tokens.shadow),
        ]
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
