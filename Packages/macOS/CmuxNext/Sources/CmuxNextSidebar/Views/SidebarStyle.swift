import AppKit
import CmuxNextDesign

/// Sidebar sizes and fonts, derived only from CmuxNextDesign tokens
/// (`Metrics`, `Typography`). Hierarchy comes from weight and gray level.
enum SidebarStyle {
    static var horizontalInset: CGFloat { Metrics.space3 }
    static var rowCornerRadius: CGFloat { Metrics.itemCornerRadius }
    static var tabIconSize: CGFloat { Metrics.smallIconSize - Metrics.space2 }
    /// Height of a placeholder row's bar (about a caption's x-height).
    static var placeholderBarHeight: CGFloat { Metrics.space3 }
    /// Placeholder bar widths, as shares of the title width.
    static let placeholderFractions: [CGFloat] = [0.72, 0.5, 0.62]
    /// Icon frame; the glyph inside uses `Metrics.smallIconSize`.
    static var iconBox: CGFloat { Metrics.smallIconSize + Metrics.space2 }
    static var controlSize: CGFloat { Metrics.iconSize + Metrics.space2 }
    static var toolbarButtonSize: CGFloat { Metrics.sidebarHeaderHeight }
    static var indicatorSize: CGFloat { Metrics.smallIconSize - Metrics.space1 }
    static var dotSize: CGFloat { Metrics.space3 }
    /// A window rail button's glyph box and glyph (the Codex rail's 15pt
    /// glyphs on 32pt tiles), and its tile's rounding.
    static var railIconBox: CGFloat { Metrics.iconSize + Metrics.space3 }
    static var railGlyphSize: CGFloat { Metrics.iconSize + 1 }
    static var railTileCornerRadius: CGFloat { Metrics.itemCornerRadius + Metrics.space1 }
    /// The glyph well of a large sidebar-top tile (the tiles arrangement).
    static var favoriteWell: CGFloat { Metrics.sidebarRowHeight + Metrics.space1 }
    static var badgeHeight: CGFloat { Metrics.iconSize }
    static var searchHeight: CGFloat { Metrics.sidebarRowHeight }
    static var footerHeight: CGFloat { Metrics.sidebarRowHeightWithSubtitle - Metrics.space2 }
    static var autoscrollZone: CGFloat { Metrics.sidebarRowHeight }
    static var dragThreshold: CGFloat { Metrics.space2 }
    static var overscan: CGFloat { Metrics.sidebarRowHeightWithSubtitle * 10 }

    static var titleFont: NSFont { Typography.bodyEmphasized }
    /// Length of the fade that ends a clipped row title (no ellipsis).
    static var titleFadeWidth: CGFloat { Metrics.space6 }
    static var titleUnreadFont: NSFont { Typography.bodyEmphasized }
    static var subtitleFont: NSFont { Typography.caption }
    /// Where workspace titles start: past the leading type glyph every row
    /// reserves. Group headers start their name here too.
    static var titleLeading: CGFloat { horizontalInset + iconBox + Metrics.space3 }
    static var headerFont: NSFont { Typography.header }
    static var badgeFont: NSFont { Typography.shortcut }
    static var glyphConfig: NSImage.SymbolConfiguration { .init(pointSize: Metrics.smallIconSize - Metrics.space1, weight: .regular) }
    static var chevronConfig: NSImage.SymbolConfiguration { .init(pointSize: Metrics.smallIconSize - Metrics.space2, weight: .bold) }

    /// Muted tint for a user color, shared with tab groups (`GroupColor`).
    static func color(_ color: GroupColor) -> NSColor {
        color.swatch
    }

}
