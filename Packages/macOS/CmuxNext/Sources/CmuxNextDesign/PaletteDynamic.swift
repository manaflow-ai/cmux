public import AppKit

/// The app-theme (Ghostty config) dynamic colors behind `Palette`, used
/// outside a scope context. Each resolves against `ThemeSnapshot` whenever
/// it is drawn, so it follows a config reload with only a redraw.
enum PaletteDynamic {
    static let windowBackground = token(\.windowBackground)
    static let sidebarBackground = token(\.sidebarBackground)
    static let contentBackground = token(\.contentBackground)
    static let pageBackground = token(\.contentBackground, opaque: true)
    static let utilityWindowBackground = token(\.windowBackground, opaque: true)
    static let chromeBackground = token(\.chromeBackground)
    static let elevatedBackground = token(\.elevatedBackground)
    static let stripBackground = token(\.stripBackground)
    static let textPrimary = token(\.textPrimary)
    static let textSecondary = token(\.textSecondary)
    static let textTertiary = token(\.textTertiary)
    static let hoverFill = token(\.hoverFill)
    static let selectionFill = token(\.selectionFill)
    static let secondarySelectionFill = token(\.secondarySelectionFill)
    static let pressedFill = token(\.pressedFill)
    static let badgeFill = token(\.badgeFill)
    static let focusRing = token(\.focusRing)
    static let separator = token(\.separator)
    static let paneBorder = token(\.paneBorder)
    static let glassTint = token(\.glassTint)
    static let shadow = token(\.shadow)
    static let textSelection = token(\.textSelection)
    static let attention = token(\.attention)
    static let danger = token(\.danger)
    static let success = token(\.success)
    static let textOnPrimary = token(\.contentBackground, opaque: true)

    private static func token(_ keyPath: any KeyPath<ThemeTokens, ThemeRGB> & Sendable, opaque: Bool = false) -> NSColor {
        NSColor(name: nil) { _ in
            let rgb = ThemeSnapshot.tokens[keyPath: keyPath]
            return (opaque ? rgb.withAlpha(1) : rgb).nsColor
        }
    }
}
