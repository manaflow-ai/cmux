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
            failure: color(Palette.danger, opaque: true))
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
        palette.background = color(Palette.fill(for: .home, default: Palette.paneFill), opaque: false)
        return palette
    }

    private static func color(_ c: NSColor, opaque: Bool) -> HomeColor {
        let s = c.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        return HomeColor(red: s.redComponent, green: s.greenComponent, blue: s.blueComponent, alpha: opaque ? 1 : s.alphaComponent)
    }
}
