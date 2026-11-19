import AppKit
import CmuxNextDesign

/// The Team section's colors, from the theme tokens of the window that hosts it.
nonisolated struct CloudTeamColors: Equatable {
    var text: NSColor
    var secondary: NSColor
    var tertiary: NSColor
    var hover: NSColor
    var selection: NSColor
    var attention: NSColor

    /// The colors for `tokens` (a window's theme scope).
    init(tokens: ThemeTokens) {
        text = tokens.textPrimary.nsColor
        secondary = tokens.textSecondary.nsColor
        tertiary = tokens.textTertiary.nsColor
        hover = tokens.hoverFill.nsColor
        selection = tokens.selectionFill.nsColor
        attention = tokens.attention.nsColor
    }
}
