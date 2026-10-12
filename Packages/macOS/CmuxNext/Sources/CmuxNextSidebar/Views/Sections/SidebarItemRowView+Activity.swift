import AppKit
import CmuxNextDesign

// A workspace item's status in the shared indicator (`StatusIndicatorView`, cx-ag5.2): trailing
// before the badge on a row, as a workspace row draws it; on the glyph's bottom trailing corner
// on an icon or a tile, opposite the unread dot.
extension SidebarItemRowView {
    /// Icons and tiles have no room for a count: unread items show a dot
    /// at the glyph's top trailing corner (the rail, like the Codex app's).
    var unreadState: UnreadState {
        if info.unreadDot { return .dot }
        let unread = (info.badge ?? 0) > 0
        if style == .favorite { return unread ? .dot : .none }
        if style.isIconOnly { return isRailButton && unread ? .dot : .none }
        return info.badge.map(UnreadState.count) ?? .none
    }

    /// Where the title ends: before the indicator, which sits before `badgeX` while it draws (a
    /// chip without a badge keeps its padding after the indicator).
    func activityLeading(before badgeX: CGFloat) -> CGFloat {
        guard activity.showsGlyph else { return badgeX }
        return badgeX - SidebarStyle.indicatorSize - (badge.isHidden && style != .chip ? 0 : Metrics.space2)
    }

    /// Places the indicator after a row or icon layout.
    func layoutActivity(in bounds: NSRect) {
        guard activity.showsGlyph else { return activity.frame = .zero }
        if style.isIconOnly { return layoutActivity(onGlyph: icon.frame) }
        let side = SidebarStyle.indicatorSize
        activity.frame = NSRect(x: title.frame.maxX + Metrics.space2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    /// The indicator on `glyph`'s bottom trailing corner.
    func layoutActivity(onGlyph glyph: NSRect) {
        guard activity.showsGlyph else { return activity.frame = .zero }
        let side = SidebarStyle.dotSize * 2
        activity.frame = NSRect(x: glyph.maxX - side / 2, y: glyph.maxY - side / 2, width: side, height: side)
    }
}
