public import CmuxNextDesign
import GhosttyNextKit

extension GhosttyThemeColors {
    /// The Ghostty config lines that keep this terminal theme readable over `surface`, the App
    /// Theme's veil a terminal draws on in a see-through window: `foreground` and each `palette`
    /// entry under `minimum` contrast, moved toward black or white until it reads (its hue kept,
    /// `ThemeTokens.readable`). Colors that already read get no line. Empty: nothing to change.
    /// - Parameters:
    ///   - surface: The veil color the cells draw over.
    ///   - minimum: The WCAG contrast ratio every text color must reach (4.5:1, AA body text).
    public func contrastLines(over surface: ThemeRGB, minimum: Double = 4.5) -> [String] {
        []
    }
}

extension GhosttyRuntime {
    /// A copy of `base` with `lines` loaded over it, for one surface (``TerminalSession``'s veil
    /// contrast); the caller owns it. Nil when libghostty cannot clone it or `lines` is empty.
    static func surfaceConfig(_ base: ghostty_config_t, lines: [String]) -> ghostty_config_t? {
        nil
    }
}
