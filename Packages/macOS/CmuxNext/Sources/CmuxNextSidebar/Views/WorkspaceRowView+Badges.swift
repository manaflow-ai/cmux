import AppKit
import CmuxNextDesign
import Foundation

/// The row's state badge (`SidebarRowBadgeStyle`, Leo and Lawrence 2026-10-14): no count number.
/// It always draws in the trailing slot, with or without an icon: nothing but the favicon or the
/// user's icon draws in the leading slot (Lawrence 2026-10-19, "There should only ever be a single
/// unread indicator for the right side"), so a row with a favicon and a text-only row
/// (WORKSPACE-ROWS-NO-DEFAULT-ICON) put it in the same place. With `sidebar.showTimestamps`
/// on (off by default), the right side shows the dim time since the last change.
extension WorkspaceRowView {
    /// Applies `style` after the rest of `configure`: the row badge and the trailing time. `trailing` leaves the row as it was.
    func configureBadges(_ ws: SidebarWorkspace, shown: WorkspaceRowContent, style: SidebarRowBadgeStyle,
                         stackLimit: Int = SidebarRowBadgeStackCap.tunable.defaultValue.limit) {
        let badges = WorkspaceRowBadges(unread: ws.unread, activity: shown.activity, stackLimit: stackLimit,
                                        detailed: shown.detailedStatus)
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
        // One glyph (`corner`) or the stack, in the trailing slot. A stack keeps its chips only
        // when glyphs overlap; a lone glyph is bare (no disc behind the spinner or the unread dot,
        // Lawrence 2026-10-18).
        let states = corner ? badges.first.map { [$0] } ?? [] : badges.stacked
        rowBadge.configure(states, look: states.count > 1 ? .stack : .plain)
        rowBadge.themedToolTip = Self.badgeSummary(badges, stacked: !corner)
    }

    /// What the badges say, for the tooltip: the count, then each state, then what the stack left out
    /// (`stacked`; the corner badge shows one glyph and lists every state).
    static func badgeSummary(_ badges: WorkspaceRowBadges, stacked: Bool) -> String? {
        var parts: [String] = []
        if badges.unreadCount > 0 { parts.append(Strings.unreadCount(badges.unreadCount)) }
        for state in badges.pending where state != .success {
            if let text = Strings.activity(state), !parts.contains(text) { parts.append(text) }
        }
        if stacked, badges.overflow > 0 { parts.append(Strings.statusMore(badges.overflow)) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Places the badge (one glyph or the stack) left of `trailing`, centered on `cy`; returns the
    /// new trailing edge. Never on the leading icon.
    ///
    /// With `columnCenterX` (nothing else sits at the row's end), the last glyph centers on the
    /// trailing column instead, the x the group header's chevron centers on, so every row's dot
    /// and spinner share one line (Lawrence 2026-10-20); the whole column slot stays reserved.
    func layoutRowBadge(trailing: CGFloat, cy: CGFloat, columnCenterX: CGFloat? = nil) -> CGFloat {
        guard !rowBadge.isHidden else { return trailing }
        // Whole points, so each glyph in its cell lands on the pixel grid at 1x and 2x.
        let side = rowBadge.cellSide, width = rowBadge.preferredWidth
        let x = columnCenterX.map { $0 - width + side / 2 } ?? trailing - width
        rowBadge.frame = NSRect(x: x.rounded(.down), y: (cy - side / 2).rounded(), width: width, height: side)
        let slotStart = columnCenterX.map { $0 - SidebarStyle.trailingSlotSide / 2 } ?? rowBadge.frame.minX
        return min(rowBadge.frame.minX, slotStart) - Metrics.space2
    }

    /// The row's backdrop for the badges' cutout rings: `fill` over the sidebar's background.
    static func badgeBackdrop(_ fill: NSColor?) -> CGColor {
        let base = Palette.sidebarBackground.usingColorSpace(.sRGB) ?? Palette.sidebarBackground
        guard let fill = fill?.usingColorSpace(.sRGB) else { return base.cgColor }
        let blended = base.blended(withFraction: fill.alphaComponent, of: fill.withAlphaComponent(1)) ?? base
        return blended.cgColor
    }
}
