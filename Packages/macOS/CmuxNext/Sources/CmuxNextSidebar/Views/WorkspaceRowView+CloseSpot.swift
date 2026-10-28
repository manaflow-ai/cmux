import AppKit
import CmuxNextDesign

extension WorkspaceRowView {
    /// Moves the hover close among the trailing controls per `sidebar.rowCloseSpot` (`SidebarRowCloseSpot`), after
    /// the standard layout put it between the menu and the chevron. `columnMark`: the status mark on the trailing
    /// column, if any. Returns whether that mark gives way to the hover controls (the layout's mark pass hides it);
    /// runs on every layout, so the mark comes back when the hover ends. Leo 2026-10-28: "If you're hovering over a
    /// workspace or whatever, just don't show the spinner": while the close or the menu shows, the mark never does.
    func placeCloseSpot(columnMark: NSView?, rowWidth: CGFloat, cy: CGFloat, control: CGFloat,
                        showClose: Bool, showMore: Bool) -> Bool {
        let givesWay = columnMark != nil && (showClose || showMore)
        let spot = SidebarTunables.rowCloseSpot.value
        if spot == .even, columnMark != nil {
            // The column's gap is `space2`, the controls' `space1`: the cluster moves right by the difference.
            let dx = Metrics.space2 - Metrics.space1
            for view in [disclosureButton, closeButton, moreButton, pinButton] { view.frame = view.frame.offsetBy(dx: dx, dy: 0) }
        }
        guard spot.atEnd else { return givesWay }
        let column = SidebarStyle.rowCloseFrame(rowWidth: rowWidth, centerY: cy)
        if columnMark != nil, showClose {
            // ⋮ ⌄ ✕: the menu takes the close's place, the close the column's.
            moreButton.frame = closeButton.frame
            closeButton.frame = column
        } else if columnMark != nil, showMore {
            // A row that cannot close: ⌄ ⋮, the menu on the column (the pin, when shown, left of it).
            moreButton.frame = column
        } else if showClose, !disclosureButton.isHidden, disclosure != nil, disclosure != .empty {
            // No mark: the chevron ends the row; the close and the chevron trade places.
            (closeButton.frame, disclosureButton.frame) = (disclosureButton.frame, closeButton.frame)
        }
        return givesWay
    }
}
