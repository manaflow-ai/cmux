public import AppKit
public import CmuxNextDesign

/// The card's colors from the hosting surface's theme tokens: gray fills, no blue; the risk line in
/// the attention color, a held tool in danger. Kept as theme values, so equal palettes compare equal.
public struct McpConnectCardColors: Equatable, Sendable {
    private let values: Values
    let isDark: Bool

    private struct Values: Equatable, Sendable {
        var text, secondary, tertiary, surface, fill, separator, attention, danger, success: ThemeRGB
    }

    public init(tokens: ThemeTokens) {
        values = Values(text: tokens.textPrimary, secondary: tokens.textSecondary, tertiary: tokens.textTertiary,
                        surface: tokens.elevatedBackground, fill: tokens.hoverFill, separator: tokens.separator,
                        attention: tokens.attention, danger: tokens.danger, success: tokens.success)
        isDark = tokens.isDark
    }

    var text: NSColor { values.text.nsColor }
    var secondary: NSColor { values.secondary.nsColor }
    var tertiary: NSColor { values.tertiary.nsColor }
    var surface: NSColor { values.surface.nsColor }
    var fill: NSColor { values.fill.nsColor }
    var separator: NSColor { values.separator.nsColor }
    var attention: NSColor { values.attention.nsColor }
    var danger: NSColor { values.danger.nsColor }
    var success: NSColor { values.success.nsColor }
    /// The appearance the card's system controls draw in (its theme's light or dark).
    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    @MainActor var body: NSFont { Typography.body }
    @MainActor var emphasized: NSFont { Typography.bodyEmphasized }
    @MainActor var caption: NSFont { Typography.caption }
    @MainActor var header: NSFont { Typography.header }
    @MainActor var title: NSFont { Typography.subtitle }
    @MainActor var mono: NSFont { Typography.system(.monospaced, size: TypeScale.detail, weight: .regular) }
}
