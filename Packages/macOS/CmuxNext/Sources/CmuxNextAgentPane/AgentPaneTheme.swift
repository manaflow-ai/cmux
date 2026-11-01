import CmuxNextDesign
import Foundation

/// The page's theme (`window.cmuxAcpmuxBridge.applyTheme`, the TypeScript
/// `AgentSessionTheme`) derived from the Ghostty-based `ThemeTokens`, so the
/// pane matches the terminal and chrome. No blue accent (REWRITE.md visual
/// rules): the accent is `ThemeTokens.accent` (the foreground, or the theme's
/// own hue with `appearance.accent`) and its soft form the selection fill;
/// `accentText` is the opaque background (the page's base) and `onAccent`
/// the glyphs on a filled accent. The one hue is `highlight`, the theme's own
/// ANSI blue, for the primary action. `palette` is the terminal's 16 ANSI
/// colors, which the page's syntax colors use (`--agent-ansi-N`), each lifted
/// to text contrast over the code card (the elevated surface): terminals
/// tolerate a dim yellow on white that code text can't.
enum AgentPaneTheme {
    /// `motion` is the web category's policy without live resize: the page keeps these tokens
    /// after a drag ends.
    static func values(_ tokens: ThemeTokens, motion: MotionPolicy = Motion.web.policyIgnoringLiveResize,
                       surface: SurfaceKind = .agentPane) -> [String: any Sendable] {
        AgentPaneTunables.followCodexToolRuns()
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
            // Transcript response focus outlines follow the same optional focus-ring setting.
            "focusRingEnabled": DesignSettings.shared.focusRing.enabled,
            // Debug Settings agent.chatWidth; AppServices.observeBorders pushes it again on a change.
            "chatWidth": AgentPaneTunables.chatWidth.value.rawValue,
            // Debug Settings agentPane.debug.codexToolRuns, pushed again on a change as chatWidth is.
            "codexToolRuns": AgentPaneTunables.codexToolRuns.value,
            // Debug Settings agentPane.debug.liveLineBelow, pushed again on a change as codexToolRuns is.
            "liveLineBelow": AgentPaneTunables.liveLineBelow.value,
            // Debug Settings agentPane.debug.turnActionsPlacement, pushed with the theme so open
            // transcript footers follow the setting without reloading the page.
            "turnActionsPlacement": AgentPaneTunables.turnActionsPlacement.value.rawValue,
            // Debug Settings agentPane.debug.subagentTray (AgentPaneTunables+SubagentTray.swift).
            "subagentTray": AgentPaneTunables.subagentTray.value,
            // Debug Settings agentPane.debug.scrollerFade (AgentPaneTunables+ScrollerFade.swift).
            "scrollerFade": AgentPaneTunables.scrollerFade.value,
            "text": css(tokens.textPrimary),
            "mutedText": css(tokens.textSecondary),
            "softText": css(tokens.textTertiary),
            "accent": css(tokens.accent),
            "onAccent": css(tokens.onAccent),
            "accentSoft": css(tokens.selectionFill),
            "litGlyph": css(tokens.litGlyph),
            "accentText": css(opaquePage),
            "danger": css(tokens.danger),
            "warning": css(tokens.attention),
            "success": css(tokens.success),
            "highlight": css(tokens.highlight),
            "highlightText": css(tokens.highlightText),
            "shadow": css(tokens.shadow),
            "palette": tokens.ansi.prefix(16).map { color in
                css(ThemeTokens.readable(color, over: tokens.elevatedBackground, minimum: ThemeTokens.minimumTextContrast))
            },
            // The page's hover fills, focus rings, menu fades and moves (`--agent-motion-*`), in
            // seconds after ui.animationSpeed and Reduce Motion, so they pace with the chrome.
            "motion": [
                "hover": motion.duration(MotionFade.hover),
                "hoverOut": motion.duration(MotionFade.hoverOut),
                "focus": motion.duration(MotionFade.focus),
                "fadeIn": motion.duration(MotionFade.fadeIn),
                "fadeOut": motion.duration(MotionFade.fadeOut),
                "move": motion.duration(MotionSpring.move),
            ],
            // Static status indicators, or Reduce Motion (cx-sya4n): the page stops its status
            // loops and draws a shape per state (`data-status-indicators`).
            "statusIndicators": motion.reduceMotion || DesignSettings.shared.statusIndicator.animation == .static ? "static" : "animated",
            // How agent work shows on the transcript's running rows (`data-working-look`).
            "workingLook": StatusWorkingLook.tunable.value.rawValue,
        ]
    }

    /// The page's background: the content background where panes paint it
    /// (an opaque window), clear where the window root paints the one
    /// translucent sheet (`WindowBackdrop`), as the terminal leaves it.
    /// Clear on the New Tab page, which its pane backs.
    /// With the user's background for `surface` (`appearance.surfaces`,
    /// R55) it is clear: the document root paints that override once
    /// (`WebTheme`), and translucent layers must not stack on it.
    static func pageColor(_ tokens: ThemeTokens, surface: SurfaceKind = .agentPane,
                          backgrounds: SurfaceBackgrounds = ThemeScope.app.surfaceBackgrounds) -> ThemeRGB {
        if backgrounds.fill(for: surface, tokens: tokens) != nil { return tokens.surfaceBackground.withAlpha(0) }
        // The New Tab page is transparent: its pane paints the window's background under it (cx-tcju).
        if surface == .newTabPage { return tokens.surfaceBackground.withAlpha(0) }
        return WindowBackdrop.current(tokens).panesPaintBackground ? tokens.surfaceBackground.withAlpha(1) : tokens.surfaceBackground.withAlpha(0)
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
        return webTheme(tokens, surface: surface).applyScript + "window.cmuxAcpmuxBridge?.applyTheme(\(json));"
    }

    /// The shared web theme of `surface`. The New Tab page is transparent (the page background
    /// rule paints nothing) unless `appearance.surfaces.newTabPage` gives it a background: its
    /// pane backs it with the window's own background, as it backs a terminal (cx-tcju).
    @MainActor static func webTheme(_ tokens: ThemeTokens, surface: SurfaceKind,
                                    backgrounds: SurfaceBackgrounds = ThemeScope.app.surfaceBackgrounds) -> WebTheme {
        WebTheme(tokens, surface: surface, backgrounds: pageBackgrounds(tokens, surface: surface, backgrounds: backgrounds))
    }

    /// What the page of `surface` paints under its content, as ``webTheme(_:surface:backgrounds:)``
    /// gives it (`--cmux-surface-background`), in the active scope. Opaque only when the page hides
    /// everything under it, so a picture of it needs no alpha (`PageImageBackground`).
    @MainActor static func pageBackground(_ tokens: ThemeTokens, surface: SurfaceKind,
                                          backgrounds: SurfaceBackgrounds = ThemeScope.app.surfaceBackgrounds) -> ThemeRGB {
        WebTheme.pageBackground(tokens, surface: surface, backgrounds: pageBackgrounds(tokens, surface: surface, backgrounds: backgrounds))
    }

    /// `backgrounds` as the page of `surface` gets them: the New Tab page is clear unless it has its own.
    private static func pageBackgrounds(_ tokens: ThemeTokens, surface: SurfaceKind, backgrounds: SurfaceBackgrounds) -> SurfaceBackgrounds {
        var backgrounds = backgrounds
        if surface == .newTabPage, backgrounds[.newTabPage] == nil {
            backgrounds.overrides[.newTabPage] = SurfaceBackground(color: tokens.surfaceBackground.withAlpha(0))
        }
        return backgrounds
    }
}
