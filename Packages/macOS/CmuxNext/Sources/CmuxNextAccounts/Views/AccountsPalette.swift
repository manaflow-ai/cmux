public import CmuxNextDesign
import CmuxNextCodeRouter
import SwiftUI

/// Colors and type for the Accounts views, from the theme tokens of the
/// surface that hosts them (the Settings window's scope, or the app scope
/// in onboarding). Gray fills only, no blue accents.
public struct AccountsPalette: Sendable, Equatable {
    var text: Color
    var secondary: Color
    var tertiary: Color
    var card: Color
    var hover: Color
    var selection: Color
    var separator: Color
    var danger: Color
    var success: Color
    var attention: Color

    public init(tokens: ThemeTokens) {
        func color(_ rgb: ThemeRGB) -> Color { Color(nsColor: rgb.nsColor) }
        text = color(tokens.textPrimary)
        secondary = color(tokens.textSecondary)
        tertiary = color(tokens.textTertiary)
        card = color(tokens.chromeBackground)
        hover = color(tokens.hoverFill)
        selection = color(tokens.selectionFill)
        separator = color(tokens.separator)
        danger = color(tokens.danger)
        success = color(tokens.success)
        attention = color(tokens.attention)
    }

    /// The app scope's colors (the Ghostty config theme).
    @MainActor public static var app: AccountsPalette { AccountsPalette(tokens: ThemeScope.app.tokens) }

    var body: Font { Font(Typography.body) }
    var emphasized: Font { Font(Typography.bodyEmphasized) }
    var caption: Font { Font(Typography.caption) }
    var header: Font { Font(Typography.header) }

    func statusColor(_ row: AccountRowState) -> Color {
        guard row.phase != .detecting, let status = row.status else { return tertiary }
        switch status {
        case .signedIn: return success
        case .expired: return attention
        case .missing: return tertiary
        case .unknown: return secondary
        }
    }
}

extension AIProvider {
    /// A generic SF Symbol (no brand marks).
    var symbol: String {
        switch self {
        case .codex: "sparkles"
        case .claude: "asterisk"
        case .openAI, .anthropic, .openRouter, .groq, .xai, .mistral, .deepseek: "key"
        case .gemini: "diamond"
        case .bedrock, .vertex: "cloud"
        case .copilot: "chevron.left.forwardslash.chevron.right"
        case .ollama, .lmStudio: "desktopcomputer"
        case .openCodeGo: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// A small gray button (the Settings style).
struct AccountsButtonStyle: ButtonStyle {
    let palette: AccountsPalette
    var destructive = false
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(palette.body)
            .foregroundStyle(destructive ? palette.danger : palette.text)
            .padding(.horizontal, Metrics.space4)
            .padding(.vertical, Metrics.space1 + 1)
            .background(configuration.isPressed ? palette.selection : (prominent ? palette.selection : palette.hover),
                        in: RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous))
            .opacity(configuration.isPressed && prominent ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}
