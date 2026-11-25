import AppKit
import CmuxNextDesign
import CmuxNextIcons

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
    static var basePadding: CGFloat { token("omnibarButtonSpacing") ?? 3 }

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
    /// The omnibar row's gap above and below the bar. Under a tab strip its pane shows right above it (`underStrip`,
    /// ``ToolbarEdgeHosting/meetsTabStrip``): the density's `omnibarRowGap` (Default's Chrome 6 pt, Lucas 2026-11-20),
    /// never less than ``chromeGap(scale:)``. ``chromeGap(scale:)`` otherwise, for a density without the token, and under a
    /// set `layout.panePadding` (the person's padding sizes every gap), so every other density and layout keeps its gaps.
    /// On `scale`'s pixel grid.
    static func rowGap(scale: CGFloat, underStrip: Bool) -> CGFloat {
        let gap = chromeGap(scale: scale)
        guard underStrip, DesignSettings.shared.paneChrome.padding == nil, let row = token("omnibarRowGap") else { return gap }
        let pixel = max(scale, 1)
        let snapped = (row * pixel).rounded() / pixel
        return snapped.isFinite ? max(gap, snapped) : gap
    }
    /// The omnibar row's gap above the bar, from the tab pills over it: the density's `tabToOmnibarGap` when it sets one
    /// (Compact's 1 pt over its strip padding, Lucas 2026-11-20: "give compact 1 more px of bottom padding below the tab"),
    /// never less than ``chromeGap(scale:)``, else ``rowGap(scale:underStrip:)``. Only under a strip right above, as the
    /// row gap; on `scale`'s pixel grid.
    static func rowTopGap(scale: CGFloat, underStrip: Bool) -> CGFloat {
        let row = rowGap(scale: scale, underStrip: underStrip)
        guard underStrip, DesignSettings.shared.paneChrome.padding == nil, let top = token("tabToOmnibarGap") else { return row }
        let pixel = max(scale, 1)
        let snapped = (top * pixel).rounded() / pixel
        return snapped.isFinite ? max(chromeGap(scale: scale), snapped) : row
    }
    /// Space the toolbar leaves above the omnibar. The tab strip above
    /// already ends `chromeGap` below its pills (`PaneChromeMetrics`), so
    /// the omnibar starts what ``rowGap(scale:underStrip:)`` adds to that below the
    /// toolbar's top edge (0 at every density but Default), unless the pane is
    /// outlined (`layout.paneSeparation` borders: Panes, Card Outlined). The
    /// outline's top line runs along the strip's bottom, so the bar starts
    /// one row gap below that line, as the page starts one below the bar
    /// (Lawrence 2026-10-19: the space above the omnibar row equals the
    /// space below it). With no strip right above (`underStrip` false) the row is as it was before Default's Chrome gap.
    static func toolbarTopPadding(scale: CGFloat, underStrip: Bool = false) -> CGFloat {
        let row = rowTopGap(scale: scale, underStrip: underStrip)
        guard Metrics.paneBorder == .subtle else { return row - chromeGap(scale: scale) }
        return (Metrics.paneBorderWidth ?? 1 / max(scale, 1)) + row
    }
    /// The toolbar row's content height: the tallest thing in it, the toolbar
    /// buttons beside the omnibar; the omnibar-only row
    /// (`OmnibarToolbarView`) has no buttons and is the bar's height.
    static func rowContentHeight(scale: CGFloat, withButtons: Bool = true) -> CGFloat {
        withButtons ? max(barHeight(scale: scale), buttonSize(scale: scale)) : barHeight(scale: scale)
    }
    /// The omnibar's top in the toolbar row: the top padding, then half the
    /// difference to the buttons, so the bar sits on their center line.
    static func barTop(scale: CGFloat, withButtons: Bool = true, underStrip: Bool = false) -> CGFloat {
        toolbarTopPadding(scale: scale, underStrip: underStrip) + (rowContentHeight(scale: scale, withButtons: withButtons) - barHeight(scale: scale)) / 2
    }
    /// Toolbar row: the top padding, the row's content, then ``rowGap(scale:underStrip:)`` down to the page.
    static func toolbarHeight(scale: CGFloat, withButtons: Bool = true, underStrip: Bool = false) -> CGFloat {
        toolbarTopPadding(scale: scale, underStrip: underStrip) + rowContentHeight(scale: scale, withButtons: withButtons)
            + rowGap(scale: scale, underStrip: underStrip)
    }
    /// Horizontal interior margin: the back arrow's ink starts where the first tab's icon does
    /// (`Metrics.firstTabIconLeading`; Lawrence 2026-11-09: "we need proper left alignment of back
    /// arrow and the first icon of the first tab"). The arrow's ink box is
    /// `DensityTokens.toolbarGlyphInkRatio` of its glyph, centered in the square button.
    static var toolbarInset: CGFloat {
        let glyph = toolbarIconSize
        let inkLeading = (buttonSize - glyph) / 2 + glyph * (1 - DensityTokens.toolbarGlyphInkRatio) / 2
        return max(0, Metrics.firstTabIconLeading - inkLeading)
    }
    /// Toolbar buttons: square, a tab tall (`Metrics.tabBarControlSide`), as the tab bar's ⋮ above them
    /// (`OmnibarMetrics.current`; Lawrence 2026-11-23).
    static var buttonSize: CGFloat { metrics.buttonSize }
    /// The trailing buttons' gap to the pane's edge: More's center sits on the pane's trailing control
    /// column, under the tab bar's ⋮ (`Metrics.paneTrailingControlCenter`, Lawrence msg 19627).
    static var toolbarTrailingInset: CGFloat { max(0, Metrics.paneTrailingControlCenter - buttonSize / 2) }
    /// Toolbar buttons highlight in a rounded square on hover and press, at the tab's ratio on their own side, so
    /// they keep one shape at every density (Lucas 2026-11-15; Lawrence 2026-11-12, buttons round as tabs).
    static var buttonCornerRadius: CGFloat { Metrics.buttonCornerRadius(proportionalTo: buttonSize) }
    /// Toolbar button icons: `kToolbarButtonIconSize` (20 at Standard), inside Helium's 4 pt
    /// `TOOLBAR_BUTTON` insets.
    static var toolbarIconSize: CGFloat { metrics.toolbarIconSize }
    /// The star and other trailing address-bar icons, Helium's `kLocationBarTrailingIconSize`
    /// (18 at Standard; Chrome's 20 at Comfortable).
    static var trailingIconSize: CGFloat { metrics.trailingIconSize }
    /// The bookmark star's drawing side (`OmnibarMetrics.starIconSize`): 13.5 pt of ink at Compact, never more ink than its
    /// plate, which a short `browser.omnibar.height` shrinks.
    static var starIconSize: CGFloat { metrics.starIconSize }
    /// The star's button and hover plate (`OmnibarMetrics.starPlateSize`): Helium's 24 pt at Compact.
    static var starPlateSize: CGFloat { metrics.starPlateSize }
    /// The trailing badges' (the star's) gap to the bar's end: as wide as the star plate's gap to the bar's top and
    /// bottom, Helium's 2 pt at Compact.
    static var badgesTrailingInset: CGFloat { max(0, (barHeight - starPlateSize) / 2) }
    /// The plate's corners: Helium's 6 pt on 24, a quarter of its side, circular.
    static func starPlateCornerRadius(side: CGFloat) -> CGFloat { side / 4 }
    /// The plate's hover fill: Helium's over its dark bar, white at 12.8% (the bar's 68 to the plate's 92 of 255, measured
    /// from Lucas's screenshot 2026-11-18); over a light bar black at 6%, Chrome's light hover tone (not measured in Helium).
    static func starHoverFill(isDark: Bool) -> NSColor { isDark ? NSColor(white: 1, alpha: 0.128) : NSColor(white: 0, alpha: 0.06) } // colour-allow: Helium's measured star plate over its bar (Lucas 2026-11-18: "match it 1:1"); no theme token is this step
    /// The Extensions puzzle's drawing side (`OmnibarMetrics.extensionsIconSize`): 16 pt of ink at Compact.
    static var extensionsIconSize: CGFloat { metrics.extensionsIconSize }
    /// Between neighboring toolbar buttons (navigation, extensions, trailing
    /// buttons): Helium's `kToolbarIconDefaultMargin`, the base padding, which
    /// the toolbar's FlexLayout collapses to one gap.
    static var buttonSpacing: CGFloat { basePadding }
    /// Gap between the reload button and the omnibox, and the omnibox and
    /// the extension slot: Helium's `kLocationBarMargin` (twice the base padding).
    static var barMargin: CGFloat { 2 * basePadding }

    // MARK: On the window's pixels

    /// `value` on a `scale` display's pixel grid. A density's sizes are half points (Default times one factor, #44449),
    /// and a 1x display cannot draw half a point: AppKit then snapped each frame on its own, so Spacious's 37.5 pt
    /// reload button drew 38 x 37 and the 2.5 pt gaps between the toolbar buttons came out 2 and 3 pt. Snapped here
    /// once, every button, gap and bar agrees: whole points at 1x, the density's own half points at 2x.
    static func onPixels(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = max(scale, 1)
        return (value * scale).rounded() / scale
    }
    /// The backing scale `view` draws at: its window's, else the main screen's (a view not in a window yet).
    static func scale(of view: NSView?) -> CGFloat { view?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    /// ``barHeight`` on the window's pixels.
    static func barHeight(scale: CGFloat) -> CGFloat { onPixels(barHeight, scale: scale) }
    /// ``buttonSize`` on the window's pixels: the toolbar buttons stay square.
    static func buttonSize(scale: CGFloat) -> CGFloat { onPixels(buttonSize, scale: scale) }
    /// ``buttonSpacing`` on the window's pixels: one gap between every pair of toolbar buttons.
    static func buttonSpacing(scale: CGFloat) -> CGFloat { onPixels(buttonSpacing, scale: scale) }
    /// ``barMargin`` on the window's pixels.
    static func barMargin(scale: CGFloat) -> CGFloat { onPixels(barMargin, scale: scale) }

    // MARK: Omnibox

    /// The default bar radius: the bar is a tab pill's height, so it takes the tab's Chrome radius
    /// (`Metrics.tabCornerRadius`; Lawrence 2026-11-11: "same roundness as chrome"). With a radius the
    /// person set (`Metrics.cornerRadiusIsSet`) it is that radius itself (Lawrence 2026-11-05: "default
    /// roundness should be omnibar roundness"). `browser.omnibar.cornerRadius` overrides both.
    /// A browser density (one that sets `omnibarHeight`) keeps Helium's roundness on its own bar: 8 on 28, at every
    /// height (Lucas 2026-11-14: "keep the same roundness throughout all densities"; never Chrome's pill).
    static var barCornerRadius: CGFloat {
        if Metrics.cornerRadiusIsSet { return Metrics.cornerRadius }
        return token("omnibarCornerRadius")
            ?? (isBrowserDensity ? (barHeight * 8 / 28).rounded() : Metrics.tabCornerRadius)
    }
    /// The density draws a browser's location bar and card (`omnibarHeight` set): Default, Comfortable, Spacious.
    static var isBrowserDensity: Bool { token("omnibarHeight") != nil }
    /// A density's exact omnibar value (`DensityTokens.tokens[name]`, at the interface scale), or nil to derive it.
    /// Default draws Helium's location bar and Comfortable Chrome's (chrome/browser/ui/layout_constants.cc).
    static func token(_ name: String) -> CGFloat? { Metrics.tokens.tokens[name].map { Metrics.scale(CGFloat($0)) } }
    /// Page-info chip: the density's `omnibarIconViewSize` (Chrome's and Helium's 24 pt page info icon view), else
    /// the bar less 2 pt on each side.
    static var chipSize: CGFloat {
        let inset = 2 * edgeInset
        return min(token("omnibarIconViewSize") ?? barHeight - inset, barHeight - inset)
    }
    static var chipButtonCornerRadius: CGFloat { Metrics.buttonCornerRadius(proportionalTo: chipSize) }
    /// The page-info chip's x: a density's `omnibarIconLeading` (`kLocationBarLeadingDecorationEdgePadding`: Helium 2 at
    /// Default, Chrome 5 at Comfortable), else Helium's share of the bar (``BrowserChromeTuning/chipLeading(bar:chromeColumn:)``,
    /// Lawrence 2026-11-13), so the typed text and each suggestion's text start on one column (the rows take these,
    /// `OmniboxSuggestionPanel`).
    static var chipLeading: CGFloat {
        BrowserChromeTuning.override(.chipLeading) ?? token("omnibarIconLeading")
            ?? BrowserChromeTuning.chipLeading(bar: barHeight, chromeColumn: usesChromeColumn)
    }
    /// Text distance after the chip: a density's `omnibarTextGap` (`kLocationBarLeadingDecorationInnerPadding`: Helium 5,
    /// Chrome 8), else Helium's text column (``BrowserChromeTuning/textOrigin(bar:chromeColumn:)``) less the chip's end.
    static var textLeading: CGFloat {
        if let gap = token("omnibarTextGap"), BrowserChromeTuning.override(.textOrigin) == nil { return gap }
        let origin = BrowserChromeTuning.override(.textOrigin) ?? BrowserChromeTuning.textOrigin(bar: barHeight, chromeColumn: usesChromeColumn)
        return max(0, origin - chipLeading - chipSize)
    }
    /// A suggestion row's label (a label cell) draws its text this far inside its frame, where the bar's field draws at
    /// its own edge, so a row places its label this much less far in and both texts start on Helium's column: 31 pt
    /// into the bar, 38 into the card (measured in rendered views, outputs/2026-11-14-helium-match).
    static let rowLabelTextInset: CGFloat = 2
    /// How far the field moves down from the bar's center (Auto Layout's y grows down) so its baseline lands where
    /// Chromium puts the omnibox text, at a browser density (`omnibarLineBoxBaseline`): the font's line box (ascent and
    /// descent, each rounded up) centered in the bar and rounded down to a whole point, 19 pt under a 28 pt bar's top
    /// for 14 pt text, as in Helium. Centered as a label, the field drew its text half a point lower than that and
    /// than the suggestion rows. 0 at the other densities.
    static func fieldBaselineShift(field: NSTextField) -> CGFloat {
        guard token("omnibarLineBoxBaseline") != nil, let font = field.font else { return 0 }
        // The capitals center on the bar's middle, the chip icon's center, on the pixel grid (Lucas 2026-11-16: "the
        // search icon and the input text are aligned on the omnibar ... vertically aligned"), as a tab's title does.
        let scale: CGFloat = field.window?.backingScaleFactor ?? 2
        let target = ((barHeight / 2 + font.capHeight / 2) * scale).rounded() / scale
        // Where the text draws now: the field centered in the bar on whole pixels (an odd gap rounds up a pixel), its
        // baseline `firstBaselineOffsetFromTop` under its top. Measured from the drawn pixels at 2x at every density
        // (OmnibarCapitalsCenterTests): the font's unrounded ascender put the estimate 0.29 pt low at Compact, and the
        // capitals drew a pixel above the search glyph (Lucas 2026-11-17).
        let height = field.intrinsicContentSize.height
        let top = (((barHeight - height) / 2) * scale).rounded(.down) / scale
        let current = top + field.firstBaselineOffsetFromTop
        return ((target - current) * scale).rounded() / scale
    }
    /// Whether the density keeps Chrome's omnibox column (Spacious) rather than Helium's.
    static var usesChromeColumn: Bool { BrowserChromeTuning.usesChromeColumn }
    /// Where the URL's text column starts in the bar: the chip, then the gap after it (the field's edge; a suggestion
    /// row's label sits `rowLabelTextInset` less far in, so both texts start here).
    static var textOrigin: CGFloat { chipLeading + chipSize + textLeading }
    /// The bar's trailing marks' distance from its edge.
    static var edgeInset: CGFloat { token("omnibarEdgeInset") ?? 2 }
    /// The field's distance from the trailing marks.
    static var fieldTrailingGap: CGFloat { token("omnibarFieldTrailingGap") ?? 5 }
    static var trailingPadding: CGFloat { token("omnibarTrailingPadding") ?? 8 }
    static var iconPointSize: CGFloat { metrics.iconPointSize }
    /// The chip's and each suggestion row's glyph side: the density's `omnibarIconSize` (Chrome's and Helium's
    /// `kLocationBarIconSize`, 16), else the icon row size for ``iconPointSize``.
    static var iconSide: CGFloat {
        // Never past the chip it sits in: a custom density can shorten the bar under the exact size.
        min(token("omnibarIconSize") ?? .iconRowSize(forLabelPointSize: iconPointSize), chipSize)
    }
    /// The bar's text: 14 pt (`TypeScale.field`) at Standard, by density or `browser.omnibar.fontSize`.
    static var font: NSFont { Typography.system(size: metrics.fontSize, weight: TypeScale.regular) }
    static var ringWidth: CGFloat { 2 }

    // MARK: Popup

    /// The popup card is the bar grown downward: its top edge and sides are
    /// the bar's own (no outset), so it never reaches over the reload or
    /// extension buttons (`barMargin` stays clear on each side) or up into
    /// the tab strip, and its corners are the bar's corners (the look's
    /// radius, 8 pt by default), so the open bar and card are one shape.
    /// Helium's popup roundness, extrapolated on the row's height: 8.5 pt on its 19.5 pt rows (Lucas 2026-11-14:
    /// "extrapolate helium's roundness"), unless the glass look sets its own radius.
    static var cardCornerRadius: CGFloat {
        guard OmnibarGlassLook.current.cornerRadius == nil else { return OmnibarGlassLook.current.resolvedCornerRadius(barHeight: barHeight) }
        if let radius = token("omnibarPopupCornerRadius") { return radius }
        // Helium's 12 on its 28 pt rows, at every row height.
        if isBrowserDensity { return (rowHeight * 12 / 28).rounded() }
        return min((rowHeight * 17 / 39).rounded(), barHeight / 2)
    }
    /// How far the open card reaches above the bar and past its sides: the density's `omnibarPopupTopOutset` and
    /// `omnibarPopupSideOutset` (Helium's RoundedOmniboxResultsFrame: 3 above, up to the tabs, and 7 each side), else 0.
    /// How far the open card reaches above `bar`: up to the tab pills' bottom edge, measured from the bar's place in its
    /// window, so the card touches the tab above it as Helium's does at every density and in every pane (Lucas
    /// 2026-11-14: "it should be directly connected to the tab when typing"). The strip's room under its pills, then the
    /// toolbar's own top padding; a top-row strip evens its pills between the window's top edge and its bottom
    /// (`TabStripView.computeTabTop`), so its room under them follows from where the strip sits in the window.
    /// Only a horizontal tab strip right above the toolbar has tabs to reach: with the tabs at the bottom, vertical, or
    /// under the toolbar, the bar heads its pane and the card stays at its top edge (0).
    /// Default (the density with Chrome's omnibar row, `omnibarRowGap`) reaches only a strip the bar's pane shows right
    /// above it (``ToolbarEdgeHosting/meetsTabStrip``): a popup window's row has none, and its card would reach into the
    /// title bar. Every other density keeps its reach as before.
    @MainActor static func cardTopOutset(bar: NSView) -> CGFloat {
        let design = DesignSettings.shared
        guard design.tabBarPosition == .top, !design.verticalTabs, design.tabBarOrder == .aboveToolbar else { return 0 }
        let underStrip = meetsTabStrip(bar)
        if !underStrip, token("omnibarRowGap") != nil { return 0 }
        let scale = bar.window?.backingScaleFactor ?? 2
        let chrome = PaneChromeMetrics.current
        let toolbarPadding = barTop(scale: scale, underStrip: underStrip)
        // A strip lays out at its resolved height (`PaneChromeMetrics.resolvedStripHeight`), its pills the tab gap above
        // its bottom.
        let stripHeight = chrome.resolvedStripHeight(scale: scale)
        var underPills = chrome.tabGap(scale: scale)
        if let window = bar.window, let content = window.contentView, WindowTitlebar.topRowEvensPillGaps(in: window) {
            let barRect = bar.convert(bar.bounds, to: nil)
            let strip = CGRect(x: barRect.minX, y: barRect.maxY + toolbarPadding, width: barRect.width, height: stripHeight)
            if WindowTitlebar.isInTopRow(strip, in: window) {
                let tab = min(chrome.tabHeight, stripHeight)
                let row = PaneChromeMetrics(stripHeight: stripHeight, tabHeight: tab, panePadding: 0)
                let stripTop = content.bounds.maxY - strip.maxY
                underPills = max(0, stripHeight - row.pillTop(stripTop: stripTop, rim: WindowTitlebar.topRowRim(in: window), scale: scale) - tab)
            }
        }
        return underPills + toolbarPadding
    }
    /// Whether `bar` sits in an omnibar row its pane shows right under its tab strip: the nearest
    /// ``ToolbarEdgeHosting`` view around it says (the browser chrome, a page tab with a native bar); false with none.
    @MainActor static func meetsTabStrip(_ bar: NSView) -> Bool {
        var view = bar.superview
        while let current = view {
            if let host = current as? any ToolbarEdgeHosting { return host.meetsTabStrip }
            view = current.superview
        }
        return false
    }
    /// The card's reach past each side of the bar: the density's `omnibarPopupSideOutset` (Helium's 7 on its 28 pt bar),
    /// else Helium's ratio on this bar.
    static var cardSideOutset: CGFloat { token("omnibarPopupSideOutset") ?? (barHeight * 7 / 28).rounded() }
    /// Rows: bar height, touching as Chrome's do, inset so their corner is concentric with the card's, and Chrome's
    /// 11 pt on 30 under the last row.
    /// A density's `omnibarPopupRowGap` and `omnibarPopupBottomPadding` set them instead (Helium: 2 above each row, 4
    /// under the last); rows inset so their corner is concentric with the card's (4 at Default).
    /// A density's `omnibarPopupRowHeight` (Chrome's 40 pt rows under its 34 pt bar) sets it, unless the person set the
    /// bar's height (`browser.omnibar.height`): then the rows are the bar's height.
    static var rowHeight: CGFloat {
        guard OmnibarGlassAppearance.current.height == nil, let row = token("omnibarPopupRowHeight") else { return barHeight }
        return max(row, barHeight)
    }
    static var rowSideInset: CGFloat { max(edgeInset, cardCornerRadius - rowCornerRadius) }
    static var rowGap: CGFloat { token("omnibarPopupRowGap") ?? 0 }
    /// Under the last row: the row's side inset, so its bottom corners stay concentric with the card's (Lucas 2026-11-16:
    /// "concentric corners on the search across all densities").
    static var cardBottomPadding: CGFloat { rowSideInset }
    /// The highlighted row's corner: a tab's on the row's height (8 on 30), the ratio Helium's rows draw.
    /// At a browser density, Helium's 8 on its 28 pt rows at every row height, so the row stays concentric with the
    /// card across ``rowSideInset``.
    static var rowCornerRadius: CGFloat {
        token("omnibarPopupRowCornerRadius")
            ?? (isBrowserDensity ? (rowHeight * 8 / 28).rounded() : Metrics.chromeRowCornerRadius(height: rowHeight))
    }
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
    /// The bar's ink (`OmnibarInk`): fitted to every ground the bar shows with the look in effect (its rest and
    /// hover fill, glass or none, a see-through window over any desktop, the editing card), so the URL, the
    /// placeholder, the site-info chip, the star and the badges read in light, dark and custom backgrounds alike,
    /// one color per element in every state (https://github.com/manaflow-ai/cmux/issues/50986).
    static var ink: OmnibarInk { OmnibarGlassLook.current.ink } // theme-scoped
    /// The host, the typed text and the chip's label.
    static var textPrimary: NSColor { ink.primaryColor } // theme-scoped
    /// The path after the host and the placeholder.
    static var textSecondary: NSColor { ink.secondaryColor } // theme-scoped
    /// The chip's glyph, the star in both states and the badges: Chrome's `kColorOmniboxResultsIcon` tone, the primary
    /// text at 83% (#C6C6C6 over Helium's dark bar, #464747 over its light one), where that reads on the bar.
    static var iconInk: NSColor { ink.iconColor(on: [chipHoverFill, Palette.pressedFill, starHoverFill(isDark: isDarkTheme)]) } // theme-scoped
    /// Whether the active theme scope is dark.
    static var isDarkTheme: Bool { Palette.addressBar.isDark } // theme-scoped
    /// The suggestion rows' glyphs, on the card: Chrome's results-icon tone, the theme's primary text at 83%.
    static var resultsIcon: NSColor { Palette.textPrimary.withAlphaComponent(Palette.textPrimary.alphaComponent * 0.83) } // theme-scoped
}
