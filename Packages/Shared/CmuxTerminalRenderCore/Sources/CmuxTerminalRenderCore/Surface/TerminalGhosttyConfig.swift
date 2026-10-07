public import CmuxTheme
import Foundation

/// The phone's Ghostty configuration for one terminal surface, rendered as
/// Ghostty config text (`ghostty_config_load_string`). The phone has no user
/// config file: product defaults plus the user's terminal settings.
public struct TerminalGhosttyConfig: Hashable, Sendable {
    /// `ios.terminal.scrollbackBytes`: the local history window (ghostty-next
    /// section 7). Every snapshot restore applies this cap, not the host's.
    public static let defaultScrollbackLimitBytes = 8 * 1024 * 1024

    /// Points; the renderer converts to pixels with the screen scale.
    public var fontSize: Double
    public var scrollbackLimitBytes: Int
    /// The terminal colors (cmux theme tokens derive from the same input).
    /// Nil keeps Ghostty's built-in theme.
    public var theme: ThemeInput?
    public var cursorBlink: Bool

    public init(fontSize: Double = TerminalFontSizing().baseSize,
                scrollbackLimitBytes: Int = Self.defaultScrollbackLimitBytes,
                theme: ThemeInput? = nil,
                cursorBlink: Bool = false) {
        self.fontSize = fontSize
        self.scrollbackLimitBytes = max(0, scrollbackLimitBytes)
        self.theme = theme
        self.cursorBlink = cursorBlink
    }

    /// Ghostty config lines, one `key = value` per line.
    public var text: String {
        var lines = [
            "font-size = \(Self.number(fontSize))",
            "scrollback-limit-bytes = \(scrollbackLimitBytes)",
            "cursor-style-blink = \(cursorBlink)",
            // The phone draws the terminal opaque: glass never sits behind terminal text.
            "background-opacity = 1",
        ]
        if let theme {
            let tokens = ThemeTokens.derive(from: theme)
            lines.append("background = \(Self.hex(theme.background))")
            lines.append("foreground = \(Self.hex(theme.foreground))")
            for (index, color) in theme.palette.enumerated() {
                lines.append("palette = \(index)=\(Self.hex(color))")
            }
            // No accent hue: the selection is the theme's own color, else the
            // same foreground mix the chrome uses for selected text.
            let selection = theme.selectionBackground ?? tokens.textSelection
            lines.append("selection-background = \(Self.hex(selection.composited(over: theme.background)))")
            if let foreground = theme.selectionForeground {
                lines.append("selection-foreground = \(Self.hex(foreground))")
            }
            lines.append("cursor-color = \(Self.hex(tokens.textPrimary.composited(over: theme.background)))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func hex(_ color: ThemeRGB) -> String { color.withAlpha(1).description }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
