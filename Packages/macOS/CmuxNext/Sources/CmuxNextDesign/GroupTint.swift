public import AppKit
public import CmuxTheme

/// A workspace group's color (cx-25az): one of the theme palette tokens, or
/// a custom color a person picked. The wire form is the token's raw value
/// or `#RRGGBB`, the two shapes the daemon stores for a group color.
public nonisolated enum GroupTint: Hashable, Sendable {
    case palette(GroupColor)
    case custom(ThemeRGB)

    /// A token or `#RRGGBB`; nil for anything else.
    public init?(wire: String) {
        if let token = GroupColor(rawValue: wire) {
            self = .palette(token)
        } else if wire.hasPrefix("#"), let rgb = ThemeRGB(cssHex: wire) {
            self = .custom(rgb.withAlpha(1))
        } else {
            return nil
        }
    }

    /// A color from the system color panel (its hex field included), in sRGB.
    public init?(picked color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self = .custom(ThemeRGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent))
    }

    public var wire: String {
        switch self {
        case let .palette(token): token.rawValue
        case let .custom(rgb): rgb.withAlpha(1).description
        }
    }

    /// The palette token, grey (none) for a custom color.
    public var token: GroupColor {
        if case let .palette(token) = self { token } else { .grey }
    }

    /// The header bar's fill and the members' line: a custom color is kept
    /// readable over the sidebar, as the palette colors are.
    @MainActor public var headerFill: NSColor {
        switch self {
        case let .palette(token): token.headerFill
        case let .custom(rgb): Self.readable(rgb).nsColor
        }
    }

    /// The solid group header chip (cx-qno.22): its rest color and the one
    /// ink every glyph on it takes (`ThemeTokens.chip`), in the active scope.
    @MainActor public var headerChip: (fill: ThemeRGB, ink: ThemeRGB) {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let color = switch self {
        case let .palette(token): token.headerRGB(tokens)
        case let .custom(rgb): Self.readable(rgb)
        }
        return tokens.chip(color)
    }

    /// A tab group chip's fill in the active scope (`GroupColor.themedChipFill`): the color washed
    /// into the sidebar so the name stays primary text.
    @MainActor public var chipFill: NSColor {
        switch self {
        case let .palette(token): return token.themedChipFill
        case let .custom(rgb):
            let tokens = ThemeContext.active ?? ThemeScope.app.tokens
            return tokens.sidebarBackground.withAlpha(1).mixed(toward: Self.readable(rgb), tokens.isDark ? 0.34 : 0.26).nsColor
        }
    }

    /// Black or white text and glyphs on `headerFill`.
    @MainActor public var headerInk: NSColor {
        switch self {
        case let .palette(token): token.headerInk
        case let .custom(rgb): GroupColor.ink(on: Self.readable(rgb)).nsColor
        }
    }

    /// The custom color as the person picked it (the color panel starts there).
    public var picked: NSColor? {
        if case let .custom(rgb) = self { rgb.nsColor } else { nil }
    }

    @MainActor private static func readable(_ rgb: ThemeRGB) -> ThemeRGB {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        return ThemeTokens.readable(rgb.withAlpha(1), over: tokens.sidebarBackground, minimum: ThemeTokens.minimumMarkContrast)
    }
}
