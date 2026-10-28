import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextWakeups

// `sidebar.side` and `sidebar.spacesPosition` (R109): the root pins the
// sidebar to the chosen edge (`sidebarEdgePins`), frames the content and
// title beside it (`WindowRootLayout`), and passes the spaces position to
// the sidebar.
extension WindowRootView {
    /// Moves the sidebar to `sidebarSide` without animating. The layout may
    /// only move (same size), which runs no layout pass of its own, so it
    /// is marked here and lays out in the window's next pass, before the
    /// frame: pane rings and overlay rects follow, and strips under the
    /// traffic lights re-check themselves (`syncOverlay`). Nothing in this
    /// turn reads the new frames.
    func applySidebarSide() {
        applySidebarEdgePin()
        applySidebarRail()
        sidebar.side = sidebarSide
        // The right sidebar's inset moves to the other edge with it.
        applyMainPane()
        content?.needsLayout = true // invalidate: the sidebar changed sides; the content lays out at its new place.
    }

    /// Activates the sidebar's pin to the `sidebarSide` edge and ends the other one (idempotent).
    func applySidebarEdgePin() {
        for (side, pin) in sidebarEdgePins where side != sidebarSide && pin.isActive { pin.isActive = false }
        if let pin = sidebarEdgePins[sidebarSide], !pin.isActive { pin.isActive = true }
    }

    /// Follows the placement settings from `DesignSettings` while `node` shows (init reads the
    /// first values; the first value here repeats them and changes nothing).
    func observePlacement(on node: VisibilityNode, work: MainWorkScheduler) -> VisibleObservation<SidebarPlacement> {
        let sidebar = sidebar
        return VisibleObservation(node, owner: "WindowRootView.placement", on: work) { [sidebar] in
            SidebarPlacement(side: DesignSettings.shared.sidebarSide, spaces: DesignSettings.shared.spacesPosition,
                             spacesVisibility: DesignSettings.shared.spacesVisibility,
                             // `sidebar.style` = rail: the content keeps the rail's inset (`WindowRootView+SidebarRail`).
                             rail: [sidebar.model.style == .rail ? 1 : 0, sidebar.model.contentInset])
        } apply: { [weak self] placement in
            self?.applySidebarRail()
            self?.sidebarSide = placement.side
            self?.sidebar.sidebarView.spacesPosition = placement.spaces
            self?.sidebar.sidebarView.spacesVisibility = placement.spacesVisibility
        }
    }

    /// The right sidebar fills the window's height on the edge opposite the
    /// sidebar; its bar starts under the top row (`rowHeight`).
    func layoutRightPanel(rowHeight: CGFloat) {
        guard let rightPanel else { return }
        let width = rightPanelWidth
        rightPanel.isHidden = width <= 0 || presentsPage
        guard width > 0, !presentsPage else { return }
        let x = sidebarSide == .left ? bounds.width - width : 0
        rightPanel.topInset = rowHeight
        rightPanel.innerEdge = sidebarSide == .left ? .minX : .maxX
        let frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
        if rightPanel.frame != frame { rightPanel.frame = frame }
    }
}
