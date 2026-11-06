public import AppKit
public import CmuxNextDesign

/// Colors and type for the Automations page, from the theme tokens of the surface that hosts it.
///
/// The colors are kept as theme values, so two palettes compare equal when they draw the same.
public struct AutomationsPalette: Sendable, Equatable {
    private let tokens: Colors

    /// The theme values the page draws in.
    private struct Colors: Sendable, Equatable {
        var text, secondary, tertiary, background, card, hover, selection, separator, danger, success, attention: ThemeRGB
    }

    /// The palette for `tokens` (a window's theme scope).
    public init(tokens: ThemeTokens) {
        self.tokens = Colors(text: tokens.textPrimary, secondary: tokens.textSecondary, tertiary: tokens.textTertiary,
                             background: tokens.contentBackground, card: tokens.chromeBackground, hover: tokens.hoverFill,
                             selection: tokens.selectionFill, separator: tokens.separator, danger: tokens.danger,
                             success: tokens.success, attention: tokens.attention)
    }

    var text: NSColor { tokens.text.nsColor }
    var secondary: NSColor { tokens.secondary.nsColor }
    var tertiary: NSColor { tokens.tertiary.nsColor }
    var background: NSColor { tokens.background.nsColor }
    var card: NSColor { tokens.card.nsColor }
    var hover: NSColor { tokens.hover.nsColor }
    var selection: NSColor { tokens.selection.nsColor }
    var separator: NSColor { tokens.separator.nsColor }
    var danger: NSColor { tokens.danger.nsColor }
    var success: NSColor { tokens.success.nsColor }
    var attention: NSColor { tokens.attention.nsColor }

    @MainActor var body: NSFont { Typography.body }
    @MainActor var emphasized: NSFont { Typography.bodyEmphasized }
    @MainActor var caption: NSFont { Typography.caption }
    @MainActor var header: NSFont { Typography.header }

    func color(_ result: AutomationRow.LastResult) -> NSColor {
        switch result {
        case .succeeded: success
        case .failed: danger
        case .running: attention
        case .skipped, .none: tertiary
        }
    }
}
