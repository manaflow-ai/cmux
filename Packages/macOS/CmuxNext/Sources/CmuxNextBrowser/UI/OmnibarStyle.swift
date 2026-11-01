import AppKit
import CmuxNextDesign

/// Omnibar and toolbar geometry and colors. The bar, its text, the toolbar
/// buttons and their icons follow density and `browser.omnibar.height` /
/// `fontSize` (`OmnibarMetrics`; issue 28734): Standard keeps the 28 pt bar
/// with 14 pt text (chief 2026-10-15, cx-d0d.102), Comfortable is Chrome's
/// roomier 34 pt bar. Spacing,
/// spacing and hover shapes are Helium's (Lawrence 2026-10-20: "match Helium
/// not Chrome"; imputnet/helium `layout-constants.patch`, `toolbar.patch`;
/// plans/cmux-next/helium-parity.md). Focus ring, text selection and keyword
/// text use neutral grays: cmux chrome has no blue accents.
enum OmnibarStyle {
    /// Base padding: most spacing is a multiple of it (Helium's `kHeliumBasePadding`, 3).
    static let basePadding: CGFloat = 3

    // MARK: Toolbar

    /// The sizes in effect now (density and cmux.json overrides), Observation-tracked.
    static var metrics: OmnibarMetrics { .current }
    /// Omnibox height (each suggestion row's too).
    static var barHeight: CGFloat { metrics.barHeight }
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
    /// The toolbar row's content height: the tallest thing in it, the toolbar
    /// buttons beside the omnibar; the omnibar-only row
    /// (`OmnibarToolbarView`) has no buttons and is the bar's height.
    static func rowContentHeight(withButtons: Bool = true) -> CGFloat { withButtons ? max(barHeight, buttonSize) : barHeight }
    /// The omnibar's top in the toolbar row: the top padding, then half the
    /// difference to the buttons, so the bar sits on their center line.
    static func barTop(scale: CGFloat, withButtons: Bool = true) -> CGFloat {
        toolbarTopPadding(scale: scale) + (rowContentHeight(withButtons: withButtons) - barHeight) / 2
    }
    /// Toolbar row: the top padding, the row's content, then `chromeGap` down to the page.
    static func toolbarHeight(scale: CGFloat, withButtons: Bool = true) -> CGFloat {
        toolbarTopPadding(scale: scale) + rowContentHeight(withButtons: withButtons) + chromeGap(scale: scale)
    }
    /// Horizontal interior margin: the pane's chrome line, so the first
    /// button's hover shape starts where the tab pills above it start and
    /// its glyph near the tabs' icons (`Metrics.paneChromeInset`).
    static var toolbarInset: CGFloat { Metrics.paneChromeInset }
    /// Toolbar buttons: square, Helium's 28 pt at Standard (`kToolbarButtonHeight` 28),
    /// Chrome's 34 at Comfortable, by density (`OmnibarMetrics`).
    static var buttonSize: CGFloat { metrics.buttonSize }
    /// Toolbar buttons highlight in a rounded square on hover and press, Helium's
    /// `Emphasis::kHigh` (8; Chrome draws a circle, `kMaximum`).
    static var buttonCornerRadius: CGFloat { 8 }
    /// Toolbar button icons: `kToolbarButtonIconSize` (20 at Standard), inside Helium's 4 pt
    /// `TOOLBAR_BUTTON` insets.
    static var toolbarIconSize: CGFloat { metrics.toolbarIconSize }
    /// The star and other trailing address-bar icons, Helium's `kLocationBarTrailingIconSize`
    /// (18 at Standard; Chrome's 20 at Comfortable).
    static var trailingIconSize: CGFloat { metrics.trailingIconSize }
    /// Between neighboring toolbar buttons (navigation, extensions, trailing
    /// buttons): Helium's `kToolbarIconDefaultMargin`, the base padding, which
    /// the toolbar's FlexLayout collapses to one gap.
    static var buttonSpacing: CGFloat { basePadding }
    /// Gap between the reload button and the omnibox, and the omnibox and
    /// the extension slot: Helium's `kLocationBarMargin` (twice the base padding).
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
    static var iconPointSize: CGFloat { metrics.iconPointSize }
    /// The bar's text: 14 pt (`TypeScale.field`) at Standard, by density or `browser.omnibar.fontSize`.
    static var font: NSFont { Typography.system(size: metrics.fontSize, weight: TypeScale.regular) }
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
