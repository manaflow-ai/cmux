public import AppKit

/// The one scrim under a modal: native window dialogs (`OverlayScrimView`) and the web pages'
/// sheets (`--cmux-scrim`, ``WebTheme``). Light, about the Codex desktop app's: the window stays
/// readable behind the dialog (Leo 2026-10-06). Popovers anchored to a control draw none.
extension ThemeTokens {
    /// Black at this alpha: 12% in a light theme, 25% in a dark one.
    public nonisolated var scrimAlpha: CGFloat { isDark ? 0.25 : 0.12 }

    /// The scrim as a theme color.
    public nonisolated var scrim: ThemeRGB { ThemeRGB(red: 0, green: 0, blue: 0, alpha: Double(scrimAlpha)) }
}
