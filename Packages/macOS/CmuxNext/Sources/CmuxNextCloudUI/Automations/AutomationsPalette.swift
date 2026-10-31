public import CmuxNextDesign
import SwiftUI

/// Colors and type for the Automations page, from the theme tokens of the surface that hosts it.
public struct AutomationsPalette: Sendable, Equatable {
    var text: Color
    var secondary: Color
    var tertiary: Color
    var background: Color
    var card: Color
    var hover: Color
    var selection: Color
    var separator: Color
    var danger: Color
    var success: Color
    var attention: Color

    /// The palette for `tokens` (a window's theme scope).
    public init(tokens: ThemeTokens) {
        func color(_ rgb: ThemeRGB) -> Color { Color(nsColor: rgb.nsColor) }
        text = color(tokens.textPrimary)
        secondary = color(tokens.textSecondary)
        tertiary = color(tokens.textTertiary)
        background = color(tokens.contentBackground)
        card = color(tokens.chromeBackground)
        hover = color(tokens.hoverFill)
        selection = color(tokens.selectionFill)
        separator = color(tokens.separator)
        danger = color(tokens.danger)
        success = color(tokens.success)
        attention = color(tokens.attention)
    }

    var body: Font { Font(Typography.body) }
    var emphasized: Font { Font(Typography.bodyEmphasized) }
    var caption: Font { Font(Typography.caption) }
    var header: Font { Font(Typography.header) }

    func color(_ result: AutomationRow.LastResult) -> Color {
        switch result {
        case .succeeded: success
        case .failed: danger
        case .running: attention
        case .skipped, .none: tertiary
        }
    }
}
