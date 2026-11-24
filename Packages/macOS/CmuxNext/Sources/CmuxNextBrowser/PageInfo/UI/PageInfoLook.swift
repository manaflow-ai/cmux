import CmuxNextDesign
import Foundation

/// The Page Info bubble's look: today's, or one of the three redraws on the shared menu and card
/// surfaces that cmuxterm-hq RFD 0125 D10 puts to Leo ([taste] 1; Leo 2026-11-22 on the site-info
/// popover: "this \"stuff\" also looks kinda trash but maybe it's ok if that's just our style for the
/// browser"). Today's look stays the default until he picks one; the others show only when
/// `CMUX_NEXT_PAGE_INFO_LOOK` names them (a debug launch) or a test builds inside ``drawing(_:_:)``. The gallery
/// `AAPageInfoVariantsGalleryTests` draws all four.
nonisolated enum PageInfoLook: String, CaseIterable, Sendable {
    /// Today's bubble: palette rows on the transient glass.
    case current
    /// The app's menus: 28 pt rows on the menu grid (``MenuMetrics``), the menu highlight, a menu's
    /// section-style header and inset separators.
    case menu
    /// The agent pane's cards: each section its own card surface (``CardSurfaceView``) on the card
    /// radius, the card type scale, no separators.
    case card
    /// The pane header's band: a 32 pt header band across the top over full-width separators, rows on
    /// the 28 pt control row.
    case band

    /// The debug launch variable that picks a look (its raw value); anything else is ``current``.
    static let environmentKey = "CMUX_NEXT_PAGE_INFO_LOOK"

    /// The look `environment` asks for.
    static func from(environment: [String: String]) -> PageInfoLook {
        environment[environmentKey].flatMap { PageInfoLook(rawValue: $0.lowercased()) } ?? .current
    }

    /// A test's or the gallery's look for the pages it builds inside `override.withValue(look) { ... }`;
    /// nil (everywhere else) follows the launch. Scoped to the task, so no global state changes.
    static let override = TaskLocal<PageInfoLook?>(wrappedValue: nil)
    private static let launch = from(environment: ProcessInfo.processInfo.environment)
    /// The look the bubble draws now.
    static var active: PageInfoLook { override.get() ?? launch }

    /// `body`'s result, with every page and card it builds in `look`.
    static func drawing<T>(_ look: PageInfoLook, _ body: () throws -> T) rethrows -> T {
        try override.withValue(look, operation: body)
    }

    /// The redraw's numbers; nil for ``current``, which keeps `Metrics`' palette numbers.
    @MainActor var geometry: PageInfoLookGeometry? {
        switch self {
        case .current:
            nil
        case .menu:
            PageInfoLookGeometry(
                rowHeight: DesignTokens.controlRow, rowHeightWithSubtitle: DesignTokens.controlRow + DesignTokens.space3,
                cardPadding: MenuMetrics.highlightInset,
                rowLeading: MenuMetrics.iconX - MenuMetrics.highlightInset, iconColumn: MenuMetrics.iconSize,
                iconGap: MenuMetrics.iconGap, rowTrailing: MenuMetrics.trailing - MenuMetrics.highlightInset,
                fillRadius: MenuMetrics.highlightRadius,
                cornerRadius: GlassMenuMaterial.menuCornerRadius(surface: DesignTokens.radiusPopup),
                separatorInset: MenuMetrics.separatorInset - MenuMetrics.highlightInset,
                headerHeight: DesignTokens.controlRow, headerIsBand: false, sectionCards: false, sectionGap: 2,
                font: .body, headerFont: .sectionHeader)
        case .card:
            PageInfoLookGeometry(
                rowHeight: DesignTokens.controlPrimary, rowHeightWithSubtitle: DesignTokens.controlPrimary + DesignTokens.space3,
                cardPadding: DesignTokens.space2,
                rowLeading: DesignTokens.space2, iconColumn: DesignTokens.controlIcon,
                iconGap: DesignTokens.space2, rowTrailing: DesignTokens.space3,
                fillRadius: DesignTokens.radiusControl, cornerRadius: DesignTokens.radiusCard,
                separatorInset: 0, headerHeight: DesignTokens.controlPrimary, headerIsBand: false, sectionCards: true,
                sectionGap: DesignTokens.space2, font: .card, headerFont: .cardTitle)
        case .band:
            PageInfoLookGeometry(
                rowHeight: DesignTokens.controlRow, rowHeightWithSubtitle: DesignTokens.controlRow + DesignTokens.space3,
                cardPadding: 0,
                rowLeading: DesignTokens.space3, iconColumn: MenuMetrics.iconSize,
                iconGap: DesignTokens.space2, rowTrailing: DesignTokens.space3,
                fillRadius: 0, cornerRadius: DesignTokens.radiusPopup,
                separatorInset: 0, headerHeight: DesignTokens.controlPrimary, headerIsBand: true, sectionCards: false,
                sectionGap: 0, font: .body, headerFont: .sectionHeader)
        }
    }
}

/// One redraw's numbers, in points, all from the shared tokens (``DesignTokens``, ``MenuMetrics``).
nonisolated struct PageInfoLookGeometry: Equatable, Sendable {
    enum Font: Equatable, Sendable {
        /// `Typography.body` / `.bodyEmphasized`: the menus' text.
        case body
        /// `Typography.cardBody`: the cards' text.
        case card
        /// `Typography.header` in the secondary ink: a menu section's or the pane header's title.
        case sectionHeader
        /// `Typography.cardTitle`: a card's title.
        case cardTitle
    }

    var rowHeight: CGFloat
    var rowHeightWithSubtitle: CGFloat
    /// Between the bubble's edge and a row's highlight, on every side.
    var cardPadding: CGFloat
    /// From the row's (highlight's) leading edge to its icon.
    var rowLeading: CGFloat
    var iconColumn: CGFloat
    var iconGap: CGFloat
    var rowTrailing: CGFloat
    /// The hover and press highlight's corner radius.
    var fillRadius: CGFloat
    /// The bubble's outer corner radius.
    var cornerRadius: CGFloat
    /// A separator's inset from the row box on both sides.
    var separatorInset: CGFloat
    /// The header's least height.
    var headerHeight: CGFloat
    /// The header is a band across the whole bubble, over a full-width rule.
    var headerIsBand: Bool
    /// Each section (the runs between separators) draws on its own card surface; no separators.
    var sectionCards: Bool
    /// Between sections (cards), or rows' stack spacing.
    var sectionGap: CGFloat
    var font: Font
    var headerFont: Font

    /// Where a row's text starts, from the row's leading edge.
    var textX: CGFloat { rowLeading + iconColumn + iconGap }
}
