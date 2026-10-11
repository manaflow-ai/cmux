public import CmuxNextDesign
import SwiftUI

/// Colors and type of the permission surfaces, from the theme tokens of
/// the view that hosts them. Gray fills only, no blue: risk tones are the
/// theme's ANSI yellow (warning) and red (danger); read scopes stay neutral.
public struct AppPermissionsColors: Equatable {
    var text: Color
    var secondary: Color
    var tertiary: Color
    var background: Color
    var card: Color
    var field: Color
    var hover: Color
    var selection: Color
    var separator: Color
    var warning: Color
    var danger: Color
    var success: Color
    /// Text on a `text`-colored fill (the primary button).
    var onPrimary: Color

    public init(tokens: ThemeTokens) {
        func color(_ rgb: ThemeRGB) -> Color { Color(nsColor: rgb.nsColor) }
        text = color(tokens.textPrimary)
        secondary = color(tokens.textSecondary)
        tertiary = color(tokens.textTertiary)
        background = color(tokens.windowBackground.withAlpha(1))
        card = color(tokens.elevatedBackground)
        field = color(tokens.chromeBackground)
        hover = color(tokens.hoverFill)
        selection = color(tokens.selectionFill)
        separator = color(tokens.separator)
        warning = color(tokens.attention)
        danger = color(tokens.danger)
        success = color(tokens.success)
        onPrimary = color(tokens.contentBackground.withAlpha(1))
    }

    /// System grays and the system yellow and red, before a host resolves the theme.
    init() {
        text = Color(nsColor: .labelColor)
        secondary = Color(nsColor: .secondaryLabelColor)
        tertiary = Color(nsColor: .tertiaryLabelColor)
        background = Color(nsColor: .windowBackgroundColor)
        card = Color(nsColor: .controlBackgroundColor)
        field = Color(nsColor: .quaternaryLabelColor)
        hover = Color(nsColor: .quaternaryLabelColor)
        selection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        separator = Color(nsColor: .separatorColor)
        warning = Color(nsColor: .systemYellow)
        danger = Color(nsColor: .systemRed)
        success = Color(nsColor: .systemGreen)
        onPrimary = Color(nsColor: .windowBackgroundColor)
    }

    func tone(_ tone: AppRiskTone) -> Color {
        switch tone {
        case .neutral: secondary
        case .warning: warning
        case .danger: danger
        }
    }

    func tier(_ tier: AppTier) -> Color {
        switch tier {
        case .firstParty, .verified: secondary
        case .unverified: warning
        }
    }

    var body: Font { Font(Typography.body) }
    var emphasized: Font { Font(Typography.bodyEmphasized) }
    var caption: Font { Font(Typography.caption) }
    var header: Font { Font(Typography.header) }
    var title: Font { Font(Typography.subtitle).weight(.semibold) }
}

extension EnvironmentValues {
    @Entry var permissionColors = AppPermissionsColors()
}
