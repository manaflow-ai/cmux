public import CmuxNextDesign
import GhosttyNextKit

extension GhosttyThemeColors {
    /// The Ghostty config lines that keep this terminal theme readable over `surface`, the App
    /// Theme's veil a terminal draws on in a see-through window: `foreground` and each `palette`
    /// entry that reads worse on the veil than on the theme's own background, moved toward black
    /// or white (its hue kept, `ThemeTokens.readable`) back to the contrast it had there, at most
    /// `minimum`. A color the theme itself draws under `minimum` (Monokai's pink-red, a black, a
    /// muted grey) is the theme's choice, as Ghostty draws it: it is never raised past where it
    /// read, so a veil of the theme's own background changes no color. Empty: nothing to change.
    /// - Parameters:
    ///   - surface: The veil color the cells draw over.
    ///   - minimum: The WCAG contrast ratio a color is raised to at most (4.5:1, AA body text).
    public func contrastLines(over surface: ThemeRGB, minimum: Double = 4.5) -> [String] {
        func rgb(_ c: RGB) -> ThemeRGB { ThemeRGB(r: c.r, g: c.g, b: c.b) }
        let own = rgb(background)
        func raised(_ c: RGB) -> String? {
            let color = rgb(c)
            let target = min(minimum, color.contrast(with: own))
            guard color.contrast(with: surface) < target else { return nil }
            // A hair over the target, so rounding to whole bytes never lands just under it.
            return AppTheme.hex(ThemeTokens.readable(color, over: surface, minimum: target + 0.05))
        }
        var lines: [String] = []
        if let fg = raised(foreground) { lines.append("foreground = \(fg)") }
        for (index, color) in palette.enumerated() {
            if let raised = raised(color) { lines.append("palette = \(index)=\(raised)") }
        }
        return lines
    }
}

extension GhosttyRuntime {
    /// A copy of `base` with `lines` loaded over it, for one surface (``TerminalSession``'s veil
    /// contrast); the caller owns it. Nil when libghostty cannot clone it or `lines` is empty.
    static func surfaceConfig(_ base: ghostty_config_t, lines: [String]) -> ghostty_config_t? {
        guard !lines.isEmpty, let copy = ghostty_config_clone(base) else { return nil }
        for line in lines {
            line.withCString { ghostty_config_load_string(copy, $0, UInt(line.utf8.count), "cmux-next") }
        }
        ghostty_config_finalize(copy)
        return copy
    }
}
