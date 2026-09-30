import AppKit
import CmuxNextDesign

/// Omnibar and toolbar geometry and colors, taken from Helium
/// (imputnet/helium `patches/helium/ui/layout-constants.patch`,
/// `location-bar.patch`, `omnibox.patch`, `toolbar.patch`,
/// `helium-color-mixers.patch`; Chromium 154). Comfortable density uses
/// Helium's numbers; compact scales the heights down by 4 pt so the toolbar
/// stays close to a pane tab strip.
///
/// One deliberate difference: Helium draws its focus ring, text selection,
/// and keyword text in its blue primary color. cmux chrome has no blue
/// accents, so those use neutral grays.
enum OmnibarStyle {
    private static var compact: Bool { Metrics.density == .compact }

    /// Helium `kHeliumBasePadding`: most spacing is a multiple of it.
    static let basePadding: CGFloat = 3

    // MARK: Toolbar

    /// Omnibox and toolbar button height (Helium `LOCATION_BAR_HEIGHT` 28).
    static var barHeight: CGFloat { compact ? 24 : 28 }
    /// Toolbar row: the bar plus Helium's 3 pt vertical interior margin.
    static var toolbarHeight: CGFloat { barHeight + 2 * basePadding }
    /// Helium's 6 pt horizontal interior margin.
    static var toolbarInset: CGFloat { 2 * basePadding }
    /// Toolbar buttons: square, bar height, 8 pt hover shape.
    static var buttonSize: CGFloat { barHeight }
    static let buttonCornerRadius: CGFloat = 8
    static var buttonSymbolSize: CGFloat { compact ? 13 : 15 }
    static let buttonSpacing: CGFloat = 0
    /// Gap between the reload button and the omnibox, and the omnibox and
    /// the extension slot (Helium omnibox side margin).
    static var barMargin: CGFloat { 2 * basePadding }

    // MARK: Omnibox

    /// Helium `Emphasis::kHigh`.
    static let barCornerRadius: CGFloat = 8
    /// Page-info chip (Helium `kLocationBarChildCornerRadius` 6).
    static var chipSize: CGFloat { barHeight - 4 }
    static let chipCornerRadius: CGFloat = 6
    /// Chip distance from the bar's leading edge (Helium: 2).
    static let chipLeading: CGFloat = 2
    /// Text distance after the chip (Helium: 5).
    static let textLeading: CGFloat = 5
    static let trailingPadding: CGFloat = 8
    static var iconPointSize: CGFloat { compact ? 12 : 13 }
    /// Helium asks for 14 pt regular system text.
    static var font: NSFont { .systemFont(ofSize: compact ? 13 : 14, weight: .regular) }
    static var ringWidth: CGFloat { 1.5 }

    // MARK: Popup

    /// The popup card: radius 12, reaching 3 pt above the bar and 6 pt past
    /// each side so the bar sits inside it (Helium: 3 and 7; 6 keeps the
    /// card off the reload button with cmux's 6 pt gap).
    static let cardCornerRadius: CGFloat = 12
    static let cardTopOutset: CGFloat = basePadding
    static let cardSideOutset: CGFloat = 2 * basePadding
    /// Rows: bar height, inset 4 at the sides, 2 between rows, 4 at the end.
    static var rowHeight: CGFloat { barHeight }
    static let rowSideInset: CGFloat = 4
    static let rowGap: CGFloat = 2
    static let cardBottomPadding: CGFloat = 4
    static let rowCornerRadius: CGFloat = 8
    static var rowDetailFont: NSFont { font }

    // MARK: Colors

    // Helium's geometry, the terminal theme's colors (`Palette`): the
    // toolbar is the same surface as the tab strip and terminal, the bar a
    // faint lift of it, the popup a floating card. Read them only inside
    // `performWithTheme` (theme-scoped).
    static var toolbarBackground: NSColor { Palette.windowBackground } // theme-scoped
    static var barFill: NSColor { Palette.chromeBackground } // theme-scoped
    static var barHoverFill: NSColor { Palette.elevatedBackground } // theme-scoped
    /// Editing fill and popup card.
    static var cardFill: NSColor { Palette.elevatedBackground } // theme-scoped
    /// Neutral ring while editing with the popup closed (Helium: blue).
    static var ring: NSColor { Palette.focusRing } // theme-scoped
    static var rowSelectedFill: NSColor { Palette.selectionFill } // theme-scoped
    static var chipHoverFill: NSColor { Palette.hoverFill } // theme-scoped
    /// Text selection inside the field (Helium: blue tint).
    static var selection: NSColor { Palette.textSelection } // theme-scoped
    static var textPrimary: NSColor { Palette.textPrimary } // theme-scoped
    static var textSecondary: NSColor { Palette.textSecondary } // theme-scoped
}
