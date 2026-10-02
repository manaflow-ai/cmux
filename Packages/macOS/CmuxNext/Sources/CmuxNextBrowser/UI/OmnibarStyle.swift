import AppKit
import CmuxNextDesign

/// Omnibar and toolbar geometry and colors. Comfortable density uses the
/// base numbers below; compact scales the heights down by 4 pt so the
/// toolbar stays close to a pane tab strip. Focus ring, text selection and
/// keyword text use neutral grays: cmux chrome has no blue accents.
enum OmnibarStyle {
    private static var compact: Bool { Metrics.density == .compact }

    /// Base padding: most spacing is a multiple of it.
    static let basePadding: CGFloat = 3

    // MARK: Toolbar

    /// Omnibox and toolbar button height.
    static var barHeight: CGFloat { compact ? 24 : 28 }
    /// Toolbar row: the bar plus a 3 pt vertical interior margin.
    static var toolbarHeight: CGFloat { barHeight + 2 * basePadding }
    /// Horizontal interior margin: the pane's chrome line, so the first
    /// button's hover shape starts where the tab pills above it start and
    /// its glyph near the tabs' icons (`Metrics.paneChromeInset`).
    static var toolbarInset: CGFloat { Metrics.paneChromeInset }
    /// Toolbar buttons: square, bar height, 8 pt hover shape.
    static var buttonSize: CGFloat { barHeight }
    static let buttonCornerRadius: CGFloat = 8
    static var buttonSymbolSize: CGFloat { compact ? 13 : 15 }
    static let buttonSpacing: CGFloat = 0
    /// Gap between the reload button and the omnibox, and the omnibox and
    /// the extension slot.
    static var barMargin: CGFloat { 2 * basePadding }

    // MARK: Omnibox

    /// Bar corner radius.
    static let barCornerRadius: CGFloat = 8
    /// Page-info chip.
    static var chipSize: CGFloat { barHeight - 4 }
    static let chipCornerRadius: CGFloat = 6
    /// Chip distance from the bar's leading edge.
    static let chipLeading: CGFloat = 2
    /// Text distance after the chip.
    static let textLeading: CGFloat = 5
    static let trailingPadding: CGFloat = 8
    static var iconPointSize: CGFloat { compact ? 12 : 13 }
    /// 14 pt regular system text (13 pt compact).
    static var font: NSFont { .systemFont(ofSize: compact ? 13 : 14, weight: .regular) }
    static var ringWidth: CGFloat { 1.5 }

    // MARK: Popup

    /// The popup card: radius 12, reaching 3 pt above the bar and 6 pt past
    /// each side so the bar sits inside it (6 keeps the card off the
    /// reload button with cmux's 6 pt gap).
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

    // The geometry above, the terminal theme's colors (`Palette`): the
    // toolbar is the same surface as the tab strip and terminal, the bar a
    // faint lift of it, the popup a floating card. Read them only inside
    // `performWithTheme` (theme-scoped).
    static var toolbarBackground: NSColor { Palette.windowBackground } // theme-scoped
    static var barFill: NSColor { Palette.chromeBackground } // theme-scoped
    static var barHoverFill: NSColor { Palette.elevatedBackground } // theme-scoped
    /// Editing fill and popup card.
    static var cardFill: NSColor { Palette.elevatedBackground } // theme-scoped
    /// Neutral ring while editing with the popup closed.
    static var ring: NSColor { Palette.focusRing } // theme-scoped
    static var rowSelectedFill: NSColor { Palette.selectionFill } // theme-scoped
    static var chipHoverFill: NSColor { Palette.hoverFill } // theme-scoped
    /// Text selection inside the field.
    static var selection: NSColor { Palette.textSelection } // theme-scoped
    static var textPrimary: NSColor { Palette.textPrimary } // theme-scoped
    static var textSecondary: NSColor { Palette.textSecondary } // theme-scoped
}
