import AppKit
import CmuxNextDesign

/// Sidebar sizes and fonts, derived only from CmuxNextDesign tokens
/// (`Metrics`, `Typography`). Hierarchy comes from weight and gray level.
enum SidebarStyle {
    static var horizontalInset: CGFloat { Metrics.space3 }
    static var rowCornerRadius: CGFloat { Metrics.itemCornerRadius }
    /// Leading indent of grouped rows (room for the group color rail).
    static var groupIndent: CGFloat { Metrics.space5 }
    /// Icon frame; the glyph inside uses `Metrics.smallIconSize`.
    static var iconBox: CGFloat { Metrics.smallIconSize + Metrics.space2 }
    static var controlSize: CGFloat { Metrics.iconSize + Metrics.space2 }
    static var toolbarButtonSize: CGFloat { Metrics.sidebarHeaderHeight }
    static var indicatorSize: CGFloat { Metrics.smallIconSize - Metrics.space1 }
    static var dotSize: CGFloat { Metrics.space3 }
    static var badgeHeight: CGFloat { Metrics.iconSize }
    static var searchHeight: CGFloat { Metrics.sidebarRowHeight }
    static var footerHeight: CGFloat { Metrics.sidebarRowHeightWithSubtitle - Metrics.space2 }
    static var autoscrollZone: CGFloat { Metrics.sidebarRowHeight }
    static var dragThreshold: CGFloat { Metrics.space2 }
    static var overscan: CGFloat { Metrics.sidebarRowHeightWithSubtitle * 10 }

    static var titleFont: NSFont { Typography.body }
    static var titleUnreadFont: NSFont { Typography.bodyEmphasized }
    static var subtitleFont: NSFont { Typography.caption }
    static var headerFont: NSFont { Typography.header }
    static var badgeFont: NSFont { Typography.shortcut }
    static var glyphConfig: NSImage.SymbolConfiguration { .init(pointSize: Metrics.smallIconSize - Metrics.space1, weight: .regular) }
    static var chevronConfig: NSImage.SymbolConfiguration { .init(pointSize: Metrics.smallIconSize - Metrics.space2, weight: .bold) }

    /// Muted tint for a user color, shared with tab groups (`GroupColor`).
    static func color(_ color: GroupColor) -> NSColor {
        color.swatch
    }

}

