public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

/// A workspace group's color (cx-25az): one of the group palette tokens, a
/// custom color a person picked, or no color at all. The wire form is the
/// token's raw value, `#RRGGBB`, or `none`, the shapes the daemon stores for
/// a group color.
public nonisolated enum GroupTint: Hashable, Sendable {
    case palette(GroupColor)
    case custom(ThemeRGB)
    /// No color (Lawrence 2026-10-22: "need to be able to remove all workspace colors"): the
    /// header draws in the sidebar's own colors, with no dot, band, wash or members' line.
    case none

    /// The wire form of ``none``. A group with no stored color is not this: it draws a picked
    /// palette color (`GroupColor.unset(id:)`).
    public static let noneWire = "none"

    /// A token, `#RRGGBB` or `none`; nil for anything else.
    public init?(wire: String) {
        if wire == Self.noneWire {
            self = .none
        } else if let token = GroupColor(rawValue: wire) {
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
        case .none: Self.noneWire
        }
    }

    /// Whether this is no color.
    public var isNone: Bool { self == .none }

    /// The palette token, grey for a custom color or no color.
    public var token: GroupColor {
        if case let .palette(token) = self { token } else { .grey }
    }

    /// The members' line and the editors' swatches: a custom color is kept
    /// readable over the sidebar.
    @MainActor public var headerFill: NSColor {
        switch self {
        case let .palette(token): token.headerFill
        case let .custom(rgb): Self.readable(rgb).nsColor
        case .none: .clear
        }
    }

    /// The solid group header chip (cx-qno.22): its rest color and the one
    /// ink every glyph on it takes (`ThemeTokens.chip`), in the active scope.
    /// The ink is white or near-black, whichever reads better on the color
    /// (cg-design-judge 2026-10-14: the theme's text color read grey on a dark
    /// green header).
    @MainActor public var headerChip: (fill: ThemeRGB, ink: ThemeRGB) {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        // No color: the bar is the sidebar itself, its ink the sidebar's text.
        if isNone { return (tokens.sidebarBackground.withAlpha(1), tokens.textPrimary) }
        let color = switch self {
        case let .palette(token): token.headerRGB(tokens)
        case let .custom(rgb): Self.readable(rgb)
        case .none: tokens.sidebarBackground.withAlpha(1)
        }
        return tokens.chip(color, inks: .onColor)
    }

    /// The group's color where it draws as a line or dot, in the active scope. `themed` takes the
    /// theme's own color for the token (`GroupColor.themeRGB`, cx-7yywz); grey and a custom color
    /// stay as they are.
    @MainActor public func lineRGB(themed: Bool) -> ThemeRGB {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        return switch self {
        case let .palette(token): (themed ? token.themeRGB(tokens) : nil) ?? token.swatchRGB(tokens)
        case let .custom(rgb): Self.readable(rgb)
        // No color: a line and dot nobody sees.
        case .none: tokens.sidebarBackground.withAlpha(0)
        }
    }

    /// `lineRGB(themed:)` as a color.
    @MainActor public func lineColor(themed: Bool) -> NSColor { lineRGB(themed: themed).nsColor }

    /// The solid header bar and its ink (`headerChip`); `themed` washes the theme's color into the
    /// sidebar, as a custom color's chip does.
    @MainActor public func headerChip(themed: Bool) -> (fill: ThemeRGB, ink: ThemeRGB) {
        guard themed, case .palette = self else { return headerChip }
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let wash = tokens.sidebarBackground.withAlpha(1).mixed(toward: lineRGB(themed: true), tokens.isDark ? 0.34 : 0.26)
        return tokens.chip(wash)
    }

    /// A sidebar group's members' line under the solid band: the band's exact rest color
    /// (`headerChip(themed:).fill`, Leo 2026-10-19), so bar and line read as one group. No color: unseen (`lineRGB`).
    @MainActor public func lineFill(themed: Bool) -> NSColor { isNone ? lineColor(themed: themed) : headerChip(themed: themed).fill.nsColor }

    /// A faint wash of the group's color over the sidebar, behind a name in primary ink.
    @MainActor public func headerWash(themed: Bool) -> ThemeRGB {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        if isNone { return tokens.sidebarBackground.withAlpha(1) }
        return tokens.sidebarBackground.withAlpha(1).mixed(toward: lineRGB(themed: themed), tokens.isDark ? 0.14 : 0.10)
    }

    /// A tab group chip's fill in the active scope (`GroupColor.chipFill`); a custom color is
    /// washed into the sidebar so the name stays primary text.
    @MainActor public var chipFill: NSColor {
        switch self {
        case let .palette(token): return token.chipFill
        case let .custom(rgb):
            let tokens = ThemeContext.active ?? ThemeScope.app.tokens
            return tokens.sidebarBackground.withAlpha(1).mixed(toward: Self.readable(rgb), tokens.isDark ? 0.34 : 0.26).nsColor
        case .none:
            return .clear
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
