public import AppKit
import CmuxNextDesignTokens
public import SwiftUI

/// A native popup card's colors from its anchor's theme scope (as `BookmarkPageColors`), inks fit
/// to its glass (`GlassMenuMaterial.ink`): the browser's Downloads popup, a terminal's comments card.
public struct PopupCardColors: Equatable {
    public var primary = ThemeTokens.unresolved.textPrimary.swiftUIColor
    public var secondary = ThemeTokens.unresolved.textSecondary.swiftUIColor
    public var hover = ThemeTokens.unresolved.hoverFill.swiftUIColor
    public var separator = Color(nsColor: Borders.color(ThemeTokens.unresolved.separator.nsColor))
    public var danger = ThemeTokens.unresolved.danger.swiftUIColor

    public init() {}

    /// Call inside `performWithTheme`. theme-scoped
    @MainActor public static func resolve() -> PopupCardColors {
        var colors = PopupCardColors()
        colors.primary = glass(\.textPrimary)
        colors.secondary = glass(\.textSecondary)
        colors.hover = fixed(Palette.hoverFill)
        colors.separator = fixed(Palette.separator)
        colors.danger = fixed(Palette.danger)
        return colors
    }

    private static func fixed(_ color: NSColor) -> Color { Color(nsColor: color.usingColorSpace(.sRGB) ?? color) }
    @MainActor private static func glass(_ ink: KeyPath<ThemeTokens, ThemeRGB>) -> Color { GlassMenuMaterial.ink(ink).swiftUIColor }
}

/// A native popup card's content: a click on a control (a footer button) acts on the first click,
/// also while the popup opened without the keys.
public final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    // A main-actor generic class's isolated deinit crashes the Release compile (swift-frontend 6.3, macOS 14 target).
    nonisolated deinit {}

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
