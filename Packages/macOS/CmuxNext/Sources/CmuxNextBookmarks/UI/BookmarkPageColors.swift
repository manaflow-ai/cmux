import AppKit
import CmuxNextDesign
import SwiftUI

/// Theme colors for the SwiftUI bookmark surfaces (the manager page, the
/// edit bubble), resolved in the host view's theme scope as static colors:
/// dynamic ones would re-resolve in SwiftUI's own appearance.
struct BookmarkPageColors: Equatable {
    var background = Color.clear
    var primary = Color.primary
    var secondary = Color.secondary
    var tertiary = Color.secondary
    var hover = Color.gray.opacity(0.1)
    var selection = Color.gray.opacity(0.2)
    var separator = Color.gray.opacity(0.2)
    var danger = Color.red

    /// Call inside `performWithTheme`. theme-scoped
    static func resolve() -> BookmarkPageColors {
        BookmarkPageColors(
            background: fixed(Palette.surfaceOverride(.internalPage) ?? Palette.paneFill), primary: fixed(Palette.textPrimary), secondary: fixed(Palette.textSecondary),
            tertiary: fixed(Palette.textTertiary), hover: fixed(Palette.hoverFill), selection: fixed(Palette.selectionFill),
            separator: fixed(Palette.separator), danger: fixed(Palette.danger))
    }

    private static func fixed(_ color: NSColor) -> Color {
        Color(nsColor: color.usingColorSpace(.sRGB) ?? color)
    }
}
