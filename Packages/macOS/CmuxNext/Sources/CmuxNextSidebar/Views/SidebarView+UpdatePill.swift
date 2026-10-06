import AppKit
import CmuxNextDesign

// SIDEBAR-FOOTER-MINIMAL: the footer is one line (the bottom band: the
// avatar, then the gear) with the "Update Ready" pill trailing it while an
// update is staged. The pill is the sidebar's own view, not a band item, so
// minimal mode's band fade never hides the only update notice.
extension SidebarView {
    /// Puts the pill at the trailing end of the bottom band's last line,
    /// vertically centered on it; glyph only when the line's items leave no
    /// room for the label. Without a bottom band it sits on the footer row.
    func placeUpdatePill() {
        let pill = updatePillView
        guard pill.pill != nil else {
            pill.frame = .zero
            return
        }
        let height = SidebarUpdatePillView.height
        let trailing = bounds.width - SidebarStyle.horizontalInset
        var midY = footer.frame.midY
        var itemsEnd = SidebarStyle.horizontalInset
        let rows = belowRegion.layoutResult.rows
        if belowFade.frame.height > 0, let last = rows.max(by: { $0.frame.maxY < $1.frame.maxY }) {
            // The region is flipped and starts at the band's top.
            midY = belowFade.frame.minY + last.frame.midY
            let line = rows.filter { abs($0.frame.midY - last.frame.midY) < 1 }
            itemsEnd = max(itemsEnd, (line.map(\.frame.maxX).max() ?? 0) + Metrics.space2)
        }
        let room = trailing - itemsEnd
        pill.isCompact = pill.width(compact: false) > room
        let width = min(pill.width(compact: pill.isCompact), max(0, room))
        pill.frame = NSRect(x: trailing - width, y: midY - height / 2, width: width, height: height).integral
    }
}
