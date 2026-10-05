import CmuxNextDesign
import Foundation

/// The page's theme (`window.cmuxAcpmuxBridge.applyTheme`, the TypeScript
/// `AgentSessionTheme`) derived from the Ghostty-based `ThemeTokens`, so the
/// pane matches the terminal and chrome. No blue accent (REWRITE.md visual
/// rules): the accent is the foreground and its soft form the selection fill;
/// labels on it take the background, opaque so a translucent window's
/// backdrop doesn't thin them. The one hue is `highlight`, the theme's own
/// ANSI blue, for the primary action. `palette` is the terminal's 16 ANSI
/// colors, which the page's syntax colors use (`--agent-ansi-N`), each lifted
/// to text contrast over the code card (the elevated surface): terminals
/// tolerate a dim yellow on white that code text can't.
enum AgentPaneTheme {
    static func values(_ tokens: ThemeTokens, motion: MotionPolicy = Motion.policy,
                       surface: SurfaceKind = .agentPane) -> [String: any Sendable] {
        let page = pageColor(tokens, surface: surface)
        var opaquePage = tokens.contentBackground
        opaquePage.alpha = 1
        return [
            "isDark": tokens.isDark,
            "pageBackground": css(page),
            "surfaceBackground": css(page),
            "surfaceElevatedBackground": css(tokens.elevatedBackground),
            // The field sits on the page; it adds only the hover tint, so a
            // translucent window's backdrop shows through it as much as
            // through the terminal.
            "inputBackground": css(tokens.hoverFill),
            // appearance.borders none: every border in the page is transparent.
            "border": Borders.drawsLines ? css(tokens.separator) : "transparent",
            "borderStrong": Borders.drawsLines ? css(tokens.paneBorder) : "transparent",
            // The page's own edges (composer, menus, code and tool cards) are
            // mixed from the text color, so it also gets the mode itself.
            "borders": Borders.current.mode.rawValue,
            "text": css(tokens.textPrimary),
            "mutedText": css(tokens.textSecondary),
            "softText": css(tokens.textTertiary),
            "accent": css(tokens.textPrimary),
            "accentSoft": css(tokens.selectionFill),
            "accentText": css(opaquePage),
            "danger": css(tokens.danger),
            "warning": css(tokens.attention),
            "highlight": css(tokens.highlight),
            "highlightText": css(tokens.highlightText),
            "shadow": css(tokens.shadow),
            "palette": tokens.ansi.prefix(16).map { color in
                css(ThemeTokens.readable(color, over: tokens.elevatedBackground, minimum: ThemeTokens.minimumTextContrast))
            },
            // The page's hover fills, focus rings and menu fades (`--agent-motion-*`), in
            // seconds after ui.animationSpeed and Reduce Motion, so they pace with the chrome.
            "motion": [
                "hover": motion.duration(MotionFade.hover),
                "focus": motion.duration(MotionFade.focus),
                "fadeIn": motion.duration(MotionFade.fadeIn),
                "fadeOut": motion.duration(MotionFade.fadeOut),
            ],
        ]
    }

    /// The page's background: the content background where panes paint it
    /// (an opaque window), clear where the window root paints the one
    /// translucent sheet (`WindowBackdrop`), as the terminal leaves it.
    /// With the user's background for `surface` (`appearance.surfaces`,
    /// R55) it is clear: the document root paints that override once
    /// (`WebTheme`), and translucent layers must not stack on it.
    static func pageColor(_ tokens: ThemeTokens, surface: SurfaceKind = .agentPane,
                          backgrounds: SurfaceBackgrounds = ThemeScope.app.surfaceBackgrounds) -> ThemeRGB {
        if backgrounds.fill(for: surface, tokens: tokens) != nil { return tokens.surfaceBackground.withAlpha(0) }
        return WindowBackdrop(tokens).panesPaintBackground ? tokens.surfaceBackground.withAlpha(1) : tokens.surfaceBackground.withAlpha(0)
    }

    /// The color WebKit shows behind and around the page, the same as the
    /// page's own (`WebKitTab` leaves it clear in a translucent window too).
    static func underPageColor(_ tokens: ThemeTokens, surface: SurfaceKind = .agentPane) -> ThemeRGB {
        pageColor(tokens, surface: surface)
    }

    /// `rgba(r, g, b, a)` with 0-255 channels.
    static func css(_ color: ThemeRGB) -> String {
        func channel(_ value: Double) -> Int { Int((value * 255).rounded()) }
        let alpha = (color.alpha * 1000).rounded() / 1000
        return "rgba(\(channel(color.red)), \(channel(color.green)), \(channel(color.blue)), \(alpha))"
    }

    /// The script that applies `tokens` to a loaded page.
    static func script(_ tokens: ThemeTokens, surface: SurfaceKind = .agentPane) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: values(tokens, surface: surface), options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        // The shared web theme first (`--cmux-*`, the page background), then
        // the pane's own bridge.
        return WebTheme(tokens, surface: surface).applyScript + "window.cmuxAcpmuxBridge?.applyTheme(\(json));"
    }
}
