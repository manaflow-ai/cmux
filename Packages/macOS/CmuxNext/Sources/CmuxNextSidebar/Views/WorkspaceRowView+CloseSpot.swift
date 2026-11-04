import AppKit
import CmuxNextDesign

extension WorkspaceRowView {
    /// Moves the hover close among the trailing controls per `sidebar.rowCloseSpot` (`SidebarRowCloseSpot`), after
    /// the standard layout put it beside the menu. `columnMark`: the status mark on the trailing
    /// column, if any. Returns whether that mark gives way to the hover controls (the layout's mark pass hides it);
    /// runs on every layout, so the mark comes back when the hover ends. Leo 2026-10-28: "If you're hovering over a
    /// workspace or whatever, just don't show the spinner": while the close or the menu shows, the mark never does.
    func placeCloseSpot(columnMark: NSView?, rowWidth: CGFloat, cy: CGFloat, control: CGFloat,
                        showClose: Bool, showMore: Bool, close: inout NSRect, more: inout NSRect) -> Bool {
        let givesWay = columnMark != nil && (showClose || showMore)
        let spot = SidebarTunables.rowCloseSpot.value
        if spot == .even, let columnMark, columnMark.frame.minX < SidebarStyle.trailingColumnStart(rowWidth: rowWidth) - 0.01 {
            // A mark wider than its slot leaves a `space2` gap, the controls `space1`: the cluster moves right by the
            // difference. A mark in its slot already leaves the controls' gap (`trailingAfterColumnMark`).
            let dx = Metrics.space2 - Metrics.space1
            // The Unpin is placed from the menu button after this (`layoutPin`), so it moves with it.
            (close, more) = (close.offsetBy(dx: dx, dy: 0), more.offsetBy(dx: dx, dy: 0))
        }
        guard spot.atEnd else { return givesWay }
        let column = SidebarStyle.rowCloseFrame(rowWidth: rowWidth, centerY: cy)
        if showClose {
            // The end action stays on the column even on idle rows with counts or keycaps.
            close = column
            more = trailingActionFrame(rowWidth: rowWidth, cy: cy, control: control, minimumSlot: 1)
        } else if showMore {
            // A row that cannot close: the menu on the column (the pin, when shown, left of it).
            more = column
        }
        return givesWay
    }

    /// The next shared slot left of any still-visible tree control/chip. Both overflow and unpin
    /// use it: neither may paint over a fold chevron whose hit target would then perform another action.
    func trailingActionFrame(rowWidth: CGFloat, cy: CGFloat, control: CGFloat, minimumSlot: Int) -> CGRect {
        let fold = treeFoldSlot.made
        let contentStart = ([fold, rollUp, pullRequests] as [NSView?]).compactMap(\.self)
            .filter { !$0.isHidden && ($0 !== fold || treeFold != nil) }.map { $0.frame.minX }.min()
        let center = SidebarStyle.trailingColumnCenterX(rowWidth: rowWidth)
        let slot = contentStart.map {
            max(minimumSlot, Int(ceil((center + control / 2 + Metrics.space1 - $0) / SidebarStyle.trailingSlotPitch)))
        } ?? minimumSlot
        return SidebarStyle.trailingColumnFrame(rowWidth: rowWidth, centerY: cy, side: control, slot: slot)
    }

}
