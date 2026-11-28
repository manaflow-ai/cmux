public import AppKit
import CmuxNextDesign
public import SwiftUI

/// The chrome palette resolved in the hosting view's theme scope (room,
/// workspace, app). Static colors, so SwiftUI never re-resolves them in its
/// own appearance outside that scope.
public nonisolated struct AppSceneColors: Sendable, Equatable {
    public var background: Color
    public var elevated: Color
    public var primary: Color
    public var secondary: Color
    public var tertiary: Color
    public var separator: Color
    public var hover: Color
    public var selection: Color
    public var badge: Color
    public var success: Color
    public var attention: Color
    public var danger: Color

    /// Before the first resolve: the app theme's (`ThemeTokens.unresolved`), never macOS's grays.
    public static var fallback: AppSceneColors {
        let tokens = ThemeTokens.unresolved
        return AppSceneColors(
            background: .clear, elevated: tokens.elevatedBackground.swiftUIColor, primary: tokens.textPrimary.swiftUIColor,
            secondary: tokens.textSecondary.swiftUIColor, tertiary: tokens.textTertiary.swiftUIColor,
            separator: tokens.separator.swiftUIColor, hover: tokens.hoverFill.swiftUIColor, selection: tokens.selectionFill.swiftUIColor,
            badge: tokens.badgeFill.swiftUIColor, success: tokens.success.swiftUIColor, attention: tokens.attention.swiftUIColor,
            danger: tokens.danger.swiftUIColor)
    }

    public init(background: Color, elevated: Color, primary: Color, secondary: Color, tertiary: Color, separator: Color, hover: Color,
                selection: Color, badge: Color, success: Color, attention: Color, danger: Color) {
        self.background = background
        self.elevated = elevated
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.separator = separator
        self.hover = hover
        self.selection = selection
        self.badge = badge
        self.success = success
        self.attention = attention
        self.danger = danger
    }

    /// Resolves the palette for `view`'s theme scope.
    @MainActor
    public static func resolve(in view: NSView, useSidebarBackground: Bool = false) -> AppSceneColors {
        view.performWithTheme {
            AppSceneColors(
                background: c(useSidebarBackground ? (Palette.surfaceOverride(.sidebar) ?? Palette.sidebarBackground)
                    : (Palette.surfaceOverride(.internalPage) ?? Palette.sidebarBackground)), elevated: c(Palette.elevatedBackground), primary: c(Palette.textPrimary),
                secondary: c(Palette.textSecondary), tertiary: c(Palette.textTertiary), separator: c(Palette.separator),
                hover: c(Palette.hoverFill), selection: c(Palette.selectionFill), badge: c(Palette.badgeFill),
                success: c(Palette.success), attention: c(Palette.attention), danger: c(Palette.danger))
        }
    }

    private static func c(_ color: NSColor) -> Color { Color(nsColor: color.usingColorSpace(.sRGB) ?? color) }

    /// A token (`primary secondary tertiary accent separator success
    /// warning danger hover selected`) or `#RRGGBB[AA]`. No blue: `accent`
    /// is primary text, the emphasis cmux chrome uses.
    public func token(_ value: AppJSON?) -> Color? {
        guard let token = value?.stringValue else { return nil }
        if let hex = AppSceneStyle.hexColor(token) { return Color(nsColor: hex) }
        switch token {
        case "primary", "accent": return primary
        case "secondary": return secondary
        case "tertiary": return tertiary
        case "separator": return separator
        case "success": return success
        case "warning": return attention
        case "danger": return danger
        case "hover": return hover
        case "selected": return selection
        case "badge": return badge
        case "clear": return .clear
        default: return nil
        }
    }
}

extension EnvironmentValues {
    @Entry public var appSceneColors: AppSceneColors = .fallback
}
