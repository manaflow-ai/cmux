import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A scene `Row`'s geometry and fonts, from the sidebar's own row tokens (``SidebarRowTokens``), so an
/// app section's rows line up with the built-in rows at every `sidebar.density` and `sidebar.textSize`:
/// the same height, fill inset and corner, icon column, text column (inset, icon column, the grid's gap)
/// and title and detail fonts. Pure apart from the font cache, so a test lays out every density.
struct AppSceneRowMetrics: Equatable {
    let tokens: SidebarRowTokens
    /// `Metrics.smallIconSize`: the base of a leading glyph's side.
    let smallIconSize: CGFloat
    /// `Metrics.tabCornerRadius`: every sidebar row fill's corner (the tab pill's).
    let cornerRadius: CGFloat

    /// The tokens now; a band row's (Home, pinned rows), which an app section stands beside.
    @MainActor
    static var current: AppSceneRowMetrics {
        AppSceneRowMetrics(tokens: SidebarRowTokens.current.band, smallIconSize: Metrics.smallIconSize, cornerRadius: Metrics.tabCornerRadius)
    }

    /// The row fill's inset from the section's edges, and the content's from the fill's edges.
    var inset: CGFloat { tokens.horizontalInset }
    /// The leading icon column: the grid's icon box (16 compact, 20 comfortable), wider when the text size grows the glyph.
    var iconColumn: CGFloat {
        max(tokens.isComfortable ? LayoutGrid.iconBoxComfortable : LayoutGrid.iconBox,
            smallIconSize + tokens.textSize.glyphStep + tokens.base.space2)
    }
    /// A leading glyph's side beside the title (cap height matched to the text).
    var glyphSide: CGFloat { .iconRowSize(forLabelPointSize: tokens.titleSize) }
    /// The x where a title's ink starts, in section coordinates: two insets (fill, content), the icon column, the gap.
    func textX(hasIcon: Bool) -> CGFloat { 2 * inset + (hasIcon ? iconColumn + LayoutGrid.gap : 0) }
    /// The trailing content's end, in a section `width` wide.
    func trailingX(width: CGFloat) -> CGFloat { width - 2 * inset }

    /// A row title, regular (medium while unread), at the sidebar text size.
    @MainActor
    func titleFont(emphasized: Bool = false) -> NSFont {
        let weight: NSFont.Weight = emphasized ? .medium : .regular
        if tokens.textSize.textStep == 0 { return emphasized ? Typography.bodyEmphasized : Typography.body }
        return Typography.system(.default, size: tokens.titleSize, weight: weight)
    }

    /// A row's detail line.
    @MainActor
    var captionFont: NSFont {
        tokens.textSize.textStep == 0 ? Typography.caption : Typography.system(.default, size: tokens.captionSize, weight: .regular)
    }

    /// A row's height: one line, or one line plus the detail line's height (as a workspace row with a detail line).
    func rowHeight(detailLineHeight: CGFloat?) -> CGFloat { tokens.rowHeight + (detailLineHeight ?? 0) }
}
