import AppKit
import CmuxNextDesign

/// Omnibar and toolbar geometry and colors: one size at every density
/// (chief 2026-10-15, cx-d0d.102: a 28 pt bar with 14 pt text, the
/// reference browser's metrics). Focus ring, text selection and keyword
/// text use neutral grays: cmux chrome has no blue accents.
enum OmnibarStyle {
    /// Base padding: most spacing is a multiple of it.
    static let basePadding: CGFloat = 3

    // MARK: Toolbar

    /// Omnibox and toolbar button height.
    static var barHeight: CGFloat { 28 }
    /// The browser chrome's one vertical gap (R101): above the tab pills,
    /// from the active tab to the omnibar, and from the omnibar to the
    /// page. It is the pane chrome's tab gap (`PaneChromeMetrics.tabGap`),
    /// so density and `layout.panePadding` move all three together.
    /// `scale` is the window's backing scale (the strip snaps to it too).
    static func chromeGap(scale: CGFloat) -> CGFloat { PaneChromeMetrics.current.tabGap(scale: scale) }
    /// Space the toolbar leaves above the omnibar. The tab strip above
    /// already ends `chromeGap` below its pills (`PaneChromeMetrics`), so
    /// the omnibar starts at the toolbar's top edge, unless the pane is
    /// outlined (`layout.paneSeparation` borders: Panes, Card Outlined). The
    /// outline's top line runs along the strip's bottom, so the bar starts
    /// one `chromeGap` below that line, as the page starts one below the bar
    /// (Lawrence 2026-10-19: the space above the omnibar row equals the
    /// space below it).
    static func toolbarTopPadding(scale: CGFloat) -> CGFloat {
        guard Metrics.paneBorder == .subtle else { return 0 }
        return (Metrics.paneBorderWidth ?? 1 / max(scale, 1)) + chromeGap(scale: scale)
    }
    /// Toolbar row: the top padding, the bar, then `chromeGap` down to the page.
    static func toolbarHeight(scale: CGFloat) -> CGFloat { toolbarTopPadding(scale: scale) + barHeight + chromeGap(scale: scale) }
    /// Horizontal interior margin: the pane's chrome line, so the first
    /// button's hover shape starts where the tab pills above it start and
    /// its glyph near the tabs' icons (`Metrics.paneChromeInset`).
    static var toolbarInset: CGFloat { Metrics.paneChromeInset }
    /// Toolbar buttons: square, bar height, 8 pt hover shape.
    static var buttonSize: CGFloat { barHeight }
    static let buttonCornerRadius: CGFloat = 8
    static var buttonSymbolSize: CGFloat { 15 }
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
    static var iconPointSize: CGFloat { 13 }
    /// 14 pt regular system text (`TypeScale.field`).
    static var font: NSFont { Typography.system(size: TypeScale.field, weight: TypeScale.regular) }
    static var ringWidth: CGFloat { 2 }

    // MARK: Popup

    /// The popup card is the bar grown downward: its top edge and sides are
    /// the bar's own (no outset), so it never reaches over the reload or
    /// extension buttons (`barMargin` stays clear on each side) or up into
    /// the tab strip, and its corners are the bar's corners (the look's
    /// radius, 8 pt by default), so the open bar and card are one shape.
    static var cardCornerRadius: CGFloat { OmnibarGlassLook.current.resolvedCornerRadius(barHeight: barHeight) }
    static let cardTopOutset: CGFloat = 0
    static let cardSideOutset: CGFloat = 0
    /// Rows: bar height, inset 4 at the sides, 2 between rows, 4 at the end.
    static var rowHeight: CGFloat { barHeight }
    static let rowSideInset: CGFloat = 4
    static let rowGap: CGFloat = 2
    static let cardBottomPadding: CGFloat = 4
    /// The highlighted row's corner, concentric with the card's: the card
    /// radius less the row's inset.
    static var rowCornerRadius: CGFloat { max(0, cardCornerRadius - rowSideInset) }
    static var rowDetailFont: NSFont { font }

    // MARK: Colors

    // The geometry above, the terminal theme's colors (`Palette`): the
    // toolbar is the same surface as the tab strip and terminal, the bar a
    // faint lift of it, the popup a floating card. Read them only inside
    // `performWithTheme` (theme-scoped).
    /// The flat bar at rest or hovered: a tonal step over the toolbar that
    /// keeps a see-through window's transparency (`AddressBarSurface`).
    static func barFill(_ state: AddressBarSurface.State, coverage: Double) -> NSColor { // theme-scoped
        Palette.addressBar.fill(state, coverage: coverage).nsColor
    }
    /// Editing fill and popup card: the solid popup surface, so no page text
    /// shows through the suggestions (the field's editing card joins it).
    /// The omnibar's own card color (`AddressBarSurface.card`, chief 2026-10-15):
    /// other overlays keep `Palette.popupSurface`.
    static var cardFill: NSColor { Palette.addressBar.card.nsColor } // theme-scoped
    /// Neutral ring while editing with the popup closed.
    static var ring: NSColor { Palette.focusRing } // theme-scoped
    /// The highlighted row: the theme's accent selection when it names one,
    /// else a neutral step tuned to the bar (`AddressBarSurface`).
    static var rowSelectedFill: NSColor { Palette.selectionIsAccent ? Palette.selectionFill : Palette.addressBar.rowSelected.nsColor } // theme-scoped
    static var chipHoverFill: NSColor { Palette.hoverFill } // theme-scoped
    /// Text selection inside the field.
    static var selection: NSColor { Palette.textSelection } // theme-scoped
    static var textPrimary: NSColor { Palette.textPrimary } // theme-scoped
    static var textSecondary: NSColor { Palette.textSecondary } // theme-scoped
}
