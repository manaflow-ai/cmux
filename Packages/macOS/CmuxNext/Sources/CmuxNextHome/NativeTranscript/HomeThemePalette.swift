import AppKit
import CmuxHomeRender
import CmuxNextDesign

/// The render core's palette from the cmux-next theme, in one of the Chief
/// chat's two looks (`HomePalette.BubbleStyle`, `home.chiefBubbleStyle`).
/// The iMessage style, the default (Lawrence 2026-10-05; Leo 2026-10-19: "the
/// founders like the imessage apple blue"), is MessagesLab's measured Display
/// P3 blue and gradient with white text (`Fixture`, `measuredAccent`) and
/// Messages' grey for the Chief. The theme style, opt in for cmux's tinted
/// glass themes, gives the person's bubbles the theme's accent (a neutral step
/// of the theme when it names none) and the Chief's the theme's surface. Only
/// an accent the caller chooses (`accentOverride`) replaces either sent colour.
enum HomeThemePalette {
    /// MessagesLab's measured sent-bubble blue (catalyst Fixture.outgoing), the iMessage style's.
    static let messagesBlue = NSColor(srgbRed: 2 / 255, green: 132 / 255, blue: 254 / 255, alpha: 1) // theme-fixed: the iMessage style, the default (check-system-blue.py exception)

    /// Whether the sent bubble is MessagesLab's blue: the iMessage style with no
    /// chosen accent. Callers run inside `performWithTheme`.
    static func usesMessagesBlueInScope(style: HomePalette.BubbleStyle, accentOverride: NSColor? = nil) -> Bool { // theme-scoped
        style == .iMessage && accentOverride == nil
    }

    /// Resolves the tokens; callers run inside `performWithTheme` (theme-scoped).
    static func resolveInScope(active: Bool, style: HomePalette.BubbleStyle, accentOverride: NSColor? = nil) -> HomePalette { // theme-scoped
        let accent: NSColor = accentOverride ?? (style == .iMessage ? messagesBlue : Palette.accentFill)
        let theme = HomePalette.Theme(
            background: color(Palette.windowBackground, opaque: true),
            foreground: color(Palette.textPrimary, opaque: true),
            accent: color(accent, opaque: true),
            // The failed-send badge and its "Not Delivered" label are a status mark: systemRed's hue,
            // like the sidebar's error mark, not the theme's ANSI red (pink in Soft Blue; Leo
            // 2026-11-16: "why is this icon pink lol").
            failure: color(Palette.statusError, opaque: true))
        var palette: HomePalette
        switch style {
        case .iMessage:
            palette = HomePalette.iMessageStyled(theme, active: active)
        case .theme:
            // The theme's accent and its text when it names one (or the caller chose one); a neutral fill otherwise.
            var sent: (fill: HomeColor, text: HomeColor)?
            if accentOverride != nil {
                sent = (theme.accent, theme.accent.readableText)
            } else if Palette.hasChosenAccent {
                sent = (theme.accent, color(Palette.onAccent, opaque: true))
            }
            palette = HomePalette.themeStyled(theme, sent: sent, active: active)
        }
        // One window background (plans/cmux-next/windows.md): the scene
        // paints the pane's fill, never a tint of its own, active or not,
        // unless the user set Home's background (`appearance.surfaces.home`).
        // The secondary text reads on that fill over the window, not on the window alone.
        // Over a see-through window the composer's placeholder is the secondary text token, the web
        // fields' placeholder there (--cmux-text-secondary), so the two match pixel for pixel.
        palette = palette.onBackground(color(Palette.fill(for: .home, default: Palette.paneFill), opaque: false), over: theme.background,
                                       placeholderOverGlass: color(Palette.textSecondary, opaque: false),
                                       fieldFillOverGlass: composerSurfaceOverGlass(theme))
        return palette
    }

    /// The theme's window and text colours (accent and failure are not read), for callers that need
    /// only the surface (`composerSurfaceOverGlass`). Callers run inside `performWithTheme`.
    static func baseThemeInScope() -> HomePalette.Theme { // theme-scoped
        HomePalette.Theme(background: color(Palette.windowBackground, opaque: true), foreground: color(Palette.textPrimary, opaque: true),
                          accent: color(Palette.accentFill, opaque: true), failure: color(Palette.statusError, opaque: true))
    }

    /// The glass chrome level's tint (`--ds-glass-chrome-tint`, webviews pages/shared/desktop.css).
    static let glassChromeTint: CGFloat = 0.62

    /// The web composer's surface over a see-through window (composerStates.css): its solid colour,
    /// in a light theme the page lifted toward white (35 % page), in a dark one the page stepped 7 %
    /// toward the text, at the chrome glass tint. The Chief field takes it there, so its placeholder
    /// reads on the same fill as the web composer's.
    static func composerSurfaceOverGlass(_ theme: HomePalette.Theme) -> HomeColor {
        let page = theme.background, text = theme.foreground
        let light = 0.2126 * page.red + 0.7152 * page.green + 0.0722 * page.blue > 0.5
        func mix(_ a: CGFloat, _ b: CGFloat, _ share: CGFloat) -> CGFloat { a * share + b * (1 - share) }
        let solid: (CGFloat, CGFloat, CGFloat) = light
            ? (mix(page.red, 1, 0.35), mix(page.green, 1, 0.35), mix(page.blue, 1, 0.35))
            : (mix(text.red, page.red, 0.07), mix(text.green, page.green, 0.07), mix(text.blue, page.blue, 0.07))
        return HomeColor(red: solid.0, green: solid.1, blue: solid.2, alpha: glassChromeTint)
    }

    private static func color(_ c: NSColor, opaque: Bool) -> HomeColor {
        let s = c.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        return HomeColor(red: s.redComponent, green: s.greenComponent, blue: s.blueComponent, alpha: opaque ? 1 : s.alphaComponent)
    }
}
