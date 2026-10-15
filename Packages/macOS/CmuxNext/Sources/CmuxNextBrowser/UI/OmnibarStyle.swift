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
    /// The browser chrome's one vertical gap (R101): above the tab pills,
    /// from the active tab to the omnibar, and from the omnibar to the
    /// page. It is the pane chrome's tab gap (`PaneChromeMetrics.tabGap`),
    /// so density and `layout.panePadding` move all three together.
    /// `scale` is the window's backing scale (the strip snaps to it too).
    static func chromeGap(scale: CGFloat) -> CGFloat { PaneChromeMetrics.current.tabGap(scale: scale) }
    /// Space the toolbar leaves above the omnibar. The tab strip above
    /// already ends `chromeGap` below its pills (`PaneChromeMetrics`), so
    /// the omnibar starts at the toolbar's top edge.
    static let toolbarTopPadding: CGFloat = 0
    /// Toolbar row: the bar, then `chromeGap` down to the page.
    static func toolbarHeight(scale: CGFloat) -> CGFloat { toolbarTopPadding + barHeight + chromeGap(scale: scale) }
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
    static var font: NSFont { Typography.system(size: compact ? 13 : 14, weight: .regular) }
    static var ringWidth: CGFloat { 2 }

    // MARK: Popup

    /// The popup card: the one popup corner (`PopupStyle`, cx-iif6y),
    /// reaching 3 pt above the bar and 6 pt past each side so the bar sits
    /// inside it (6 keeps the card off the reload button with cmux's 6 pt gap).
    static var cardCornerRadius: CGFloat { PopupStyle.standard.cornerRadius }
    static let cardTopOutset: CGFloat = basePadding
    static let cardSideOutset: CGFloat = 2 * basePadding
    /// Rows: bar height, inset 4 at the sides, 2 between rows, 4 at the end.
    static var rowHeight: CGFloat { barHeight }
    static let rowSideInset: CGFloat = 4
    static let rowGap: CGFloat = 2
    static let cardBottomPadding: CGFloat = 4
    /// The popup's row corner (`PopupStyle`), inside the card's 4 pt inset.
    static var rowCornerRadius: CGFloat { PopupStyle.standard.rowCornerRadius }
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
    static var cardFill: NSColor { Palette.popupSurface } // theme-scoped
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
