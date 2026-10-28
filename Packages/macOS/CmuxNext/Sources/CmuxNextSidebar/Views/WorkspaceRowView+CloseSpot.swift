import AppKit
import CmuxNextDesign

extension WorkspaceRowView {
    /// Moves the hover close among the trailing controls per `sidebar.rowCloseSpot` (`SidebarRowCloseSpot`), after
    /// the standard layout put it between the menu and the chevron. `columnMark`: the status mark on the trailing
    /// column, if any. Returns whether that mark gives way to the close (the layout's mark pass fades it out);
    /// runs on every layout, so the mark comes back when the hover ends.
    func placeCloseSpot(columnMark: NSView?, rowWidth: CGFloat, cy: CGFloat, control: CGFloat, showClose: Bool) -> Bool {
        let spot = SidebarTunables.rowCloseSpot.value
        if spot == .even, columnMark != nil {
            // The column's gap is `space2`, the controls' `space1`: the cluster moves right by the difference.
            let dx = Metrics.space2 - Metrics.space1
            for view in [disclosureButton, closeButton, moreButton, pinButton] { view.frame = view.frame.offsetBy(dx: dx, dy: 0) }
        }
        guard spot.atEnd, showClose else { return false }
        if let columnMark {
            // ⋮ ⌄ ✕: the menu takes the close's place, the close the column's, and the mark gives way until the hover ends.
            moreButton.frame = closeButton.frame
            closeButton.frame = SidebarStyle.trailingColumnFrame(rowWidth: rowWidth, centerY: cy, side: control)
            return true
        } else if !disclosureButton.isHidden, disclosure != nil, disclosure != .empty {
            // No mark: the chevron ends the row; the close and the chevron trade places.
            (closeButton.frame, disclosureButton.frame) = (disclosureButton.frame, closeButton.frame)
        }
        return false
    }
}
