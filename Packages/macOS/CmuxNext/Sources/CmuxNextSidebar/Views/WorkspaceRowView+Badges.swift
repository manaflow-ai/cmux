import AppKit
import CmuxNextDesign
import Foundation

/// The row's state badge (`SidebarRowBadgeStyle`, Leo and Lawrence 2026-10-14): no count number.
/// The badge sits on the bottom-right corner of the row's icon when the row has one (the user's
/// icon or a favicon); a text-only row (WORKSPACE-ROWS-NO-DEFAULT-ICON) and the stack draw it in
/// the trailing slot. The right side shows the dim time since the last change.
extension WorkspaceRowView {
    /// Applies `style` after the rest of `configure`: the row badge and the trailing time. `trailing` leaves the row as it was.
    func configureBadges(_ ws: SidebarWorkspace, shown: WorkspaceRowContent, style: SidebarRowBadgeStyle,
                         stackLimit: Int = SidebarRowBadgeStackCap.tunable.defaultValue.limit, marks: WorkspaceRowStatusMarks? = nil) {
        configureStatusMarks(marks) // Group by Status: the marks draw the state, the badges leave it out
        let badges = WorkspaceRowBadges(unread: ws.unread, activity: statusMarksActivity(marks, shown.activity), stackLimit: stackLimit)
        guard style != .trailing, !isShowingPlaceholder else {
            rowBadge.configure([], look: .corner)
            return
        }
        // The icon, the cleared unread badge and the idle activity are set in `configure`.
        if timeText == nil, let time = shown.badgeTime {
            timeText = time
            timeLabel.setString(time)
        }
        let corner = style == .corner
        // A text-only row (no user icon or favicon, WORKSPACE-ROWS-NO-DEFAULT-ICON) has no icon
        // corner: its one corner glyph draws as a one-glyph stack in the trailing slot.
        let onIcon = corner && !icon.isHidden
        rowBadge.configure(corner ? badges.first.map { [$0] } ?? [] : badges.stacked, look: onIcon ? .corner : .stack)
        rowBadge.themedToolTip = Self.badgeSummary(badges, stacked: !corner)
    }

    /// What the badges say, for the tooltip: the count, then each state, then what the stack left out
    /// (`stacked`; the corner badge shows one glyph and lists every state).
    static func badgeSummary(_ badges: WorkspaceRowBadges, stacked: Bool) -> String? {
        var parts: [String] = []
        if badges.unreadCount > 0 { parts.append(Strings.unreadCount(badges.unreadCount)) }
        for state in badges.items where state != .success {
            if let text = Strings.activity(state), !parts.contains(text) { parts.append(text) }
        }
        if stacked, badges.overflow > 0 { parts.append(Strings.statusMore(badges.overflow)) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Places the corner badge on the leading icon, or the stack (and the corner glyph of a
    /// row without an icon) left of `trailing` centered on `cy`; returns the new trailing edge.
    func layoutRowBadge(style: SidebarRowBadgeStyle, trailing: CGFloat, cy: CGFloat) -> CGFloat {
        guard !rowBadge.isHidden else { return trailing }
        // Whole points, so each glyph in its cell lands on the pixel grid at 1x and 2x.
        let side = rowBadge.cellSide
        if style == .stack || icon.isHidden {
            let width = rowBadge.preferredWidth
            rowBadge.frame = NSRect(x: (trailing - width).rounded(.down), y: (cy - side / 2).rounded(), width: width, height: side)
            return rowBadge.frame.minX - Metrics.space2
        }
        // The glyph's center sits a quarter of a glyph inside the icon's bottom-right corner.
        let inset = RowBadgeView.glyphSide / 4, box = icon.frame
        rowBadge.frame = NSRect(x: (box.maxX - inset - side / 2).rounded(), y: (box.maxY - inset - side / 2).rounded(),
                                width: side, height: side)
        return trailing
    }

    /// The row's backdrop for the badges' cutout rings: `fill` over the sidebar's background.
    static func badgeBackdrop(_ fill: NSColor?) -> CGColor {
        let base = Palette.sidebarBackground.usingColorSpace(.sRGB) ?? Palette.sidebarBackground
        guard let fill = fill?.usingColorSpace(.sRGB) else { return base.cgColor }
        let blended = base.blended(withFraction: fill.alphaComponent, of: fill.withAlphaComponent(1)) ?? base
        return blended.cgColor
    }
}
