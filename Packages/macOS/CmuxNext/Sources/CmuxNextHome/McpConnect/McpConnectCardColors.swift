public import CmuxNextDesign
import SwiftUI

/// The card's colors from the hosting surface's theme tokens: gray fills, no blue; the risk line in
/// the attention color, a held tool in danger.
public struct McpConnectCardColors: Equatable, Sendable {
    var text: Color
    var secondary: Color
    var tertiary: Color
    var surface: Color
    var fill: Color
    var separator: Color
    var attention: Color
    var danger: Color
    var success: Color
    let isDark: Bool

    public init(tokens: ThemeTokens) {
        text = tokens.textPrimary.swiftUIColor
        secondary = tokens.textSecondary.swiftUIColor
        tertiary = tokens.textTertiary.swiftUIColor
        surface = tokens.elevatedBackground.swiftUIColor
        fill = tokens.hoverFill.swiftUIColor
        separator = tokens.separator.swiftUIColor
        attention = tokens.attention.swiftUIColor
        danger = tokens.danger.swiftUIColor
        success = tokens.success.swiftUIColor
        isDark = tokens.isDark
    }

    @MainActor var body: Font { Font(Typography.body) }
    @MainActor var emphasized: Font { Font(Typography.bodyEmphasized) }
    @MainActor var caption: Font { Font(Typography.caption) }
    @MainActor var header: Font { Font(Typography.header) }
    @MainActor var title: Font { Font(Typography.subtitle) }
    @MainActor var mono: Font { Font(Typography.system(.monospaced, size: TypeScale.detail, weight: .regular)) }
}
