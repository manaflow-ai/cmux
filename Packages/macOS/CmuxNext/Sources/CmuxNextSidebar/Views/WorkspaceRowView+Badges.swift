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
                                        detailed: shown.detailedStatus || ws.activityFromProgram)
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

    /// Places the row's one trailing mark on the trailing column (`SidebarStyle+TrailingColumn`, the
    /// x the group header's chevron and every band item's dot center on) and returns it with the x
    /// where the controls left of the column end; nil when the row shows no mark.
    ///
    /// The mark is the badge (one glyph or the stack, its last glyph on the column), else the agent
    /// mark that stands in for the status, else the status glyph (the `trailing` badge style), else a usage warning's
    /// triangle.
    /// Lawrence 2026-10-20: every row's dot and spinner share one line; msg 11914: whatever else the
    /// row shows (a count, the keycap, the hover close and more) sits left of it,
    /// so a selected row's dot does not move. Never on the leading icon.
    func layoutColumnMark(cy: CGFloat, rowWidth: CGFloat, markReplacesStatus: Bool) -> (view: NSView, trailing: CGFloat)? {
        let column = SidebarStyle.trailingColumnCenterX(rowWidth: rowWidth)
        let view: NSView
        if !rowBadge.isHidden {
            // The nearest backing pixel, so the last glyph's center stays on the column (a floor moved it up to a point left).
            // With no window the scale is unknown: whole points, on the pixel grid at every scale (a 2x guess put the 10 pt
            // glyph on a half point, off the 1x grid, since a row's width ends 1.5 pt from the edge, `rowEdgeGap`).
            let side = rowBadge.cellSide, width = rowBadge.preferredWidth, scale = window?.backingScaleFactor ?? 1
            rowBadge.frame = NSRect(x: SidebarStyle.pixelSnapped(column - width + side / 2, scale: scale),
                                    y: SidebarStyle.pixelSnapped(cy - side / 2, scale: scale), width: width, height: side)
            view = rowBadge
        } else if markReplacesStatus {
            agentMark.frame = statusGlyphFrame(trailing: column + SidebarStyle.statusGlyphSize / 2, centerY: cy)
            view = agentMark
        } else if activity.showsGlyph {
            activity.frame = statusGlyphFrame(trailing: column + SidebarStyle.statusGlyphSize / 2, centerY: cy)
            view = activity
        } else if !usageWarningMark.isHidden {
            // A usage warning with no status: the triangle takes the status's place, in its box (Lawrence 2026-10-30).
            usageWarningMark.frame = statusGlyphFrame(trailing: column + SidebarStyle.statusGlyphSize / 2, centerY: cy)
            view = usageWarningMark
        } else if badge.state == .dot {
            // The legacy unread style shares Search's center too. Reserve the column before
            // laying out counts or other marks, so none can occupy the dot's slot at rest.
            badge.frame = SidebarStyle.trailingColumnFrame(rowWidth: rowWidth, centerY: cy, side: SidebarStyle.unreadDotSize)
            view = badge
        } else if !machineMark.isHidden {
            // A row with no status: the machine mark takes the column, in a status mark's box, as the triangle does.
            machineMark.frame = statusGlyphFrame(trailing: column + SidebarStyle.statusGlyphSize / 2, centerY: cy)
            view = machineMark
        } else {
            return nil
        }
        return (view, SidebarStyle.trailingAfterColumnMark(markMinX: view.frame.minX, rowWidth: rowWidth))
    }

    /// The row's backdrop for the badges' cutout rings: `fill` over the sidebar's background.
    static func badgeBackdrop(_ fill: NSColor?) -> CGColor {
        let base = Palette.sidebarBackground.usingColorSpace(.sRGB) ?? Palette.sidebarBackground
        guard let fill = fill?.usingColorSpace(.sRGB) else { return base.cgColor }
        let blended = base.blended(withFraction: fill.alphaComponent, of: fill.withAlphaComponent(1)) ?? base
        return blended.cgColor
    }
}
