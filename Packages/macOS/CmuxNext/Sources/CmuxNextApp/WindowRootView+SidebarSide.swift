import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSidebar
import Observation

// `sidebar.side` and `sidebar.spacesPosition` (R109): the root pins the
// sidebar to the chosen edge (`SidebarSide.pins`), the content and title
// beside it, and passes the spaces position to the sidebar.
extension WindowRootView {
    /// Swaps the pins to `sidebarSide` without animating. The layout may
    /// only move (same size), which runs no layout pass of its own, so it
    /// is laid out here: pane rings and overlay rects follow, and strips
    /// under the traffic lights re-check themselves (`syncOverlay`).
    func applySidebarSide() {
        for (side, constraints) in sidePins where side != sidebarSide { NSLayoutConstraint.deactivate(constraints) }
        // A page with the whole window keeps the content host on the window's edges (`presentsPage`).
        NSLayoutConstraint.activate((sidePins[sidebarSide] ?? []).filter { !presentsPage || $0.firstItem !== contentHost })
        applySidebarRail()
        sidebar.side = sidebarSide
        applyMainPane()
        layoutSubtreeIfNeeded()
        content?.needsLayout = true
        content?.layoutSubtreeIfNeeded()
    }

    /// Follows the placement settings from `DesignSettings` (init reads the
    /// first values; the first emission repeats them and changes nothing).
    func observePlacement() -> Task<Void, Never> {
        let sidebar = sidebar
        return Task { [weak self] in
            for await (side, spaces, visibility, _) in ObservationStream({ [sidebar] in
                (DesignSettings.shared.sidebarSide, DesignSettings.shared.spacesPosition, DesignSettings.shared.spacesVisibility,
                 // `sidebar.style` = rail: the content keeps the rail's inset (`WindowRootView+SidebarRail`).
                 [sidebar.model.style == .rail ? 1 : 0, sidebar.model.contentInset])
            }) {
                self?.applySidebarRail()
                self?.sidebarSide = side
                self?.sidebar.sidebarView.spacesPosition = spaces
                self?.sidebar.sidebarView.spacesVisibility = visibility
            }
        }
    }
}
