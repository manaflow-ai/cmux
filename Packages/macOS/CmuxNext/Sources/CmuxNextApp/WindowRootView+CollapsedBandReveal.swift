import AppKit
import CmuxNextDesign

// Lawrence 2026-10-09: with the sidebar hidden, the pointer over the
// top-left corner (the traffic lights and the gap after them, the title bar
// row's reveal region) opens the 0-wide toolbar band to its full width, and
// the strip's tabs slide right with it (`CollapsedBandReveal`).
extension WindowRootView {
    /// The row's reveal (pointer, keyboard focus on a band button, holds) is
    /// the one input; the band's on-screen share is where an open starts.
    func setUpCollapsedBandReveal() {
        collapsedBand.install(in: self)
        collapsedBand.shownPresence = { [weak self] in self?.toolbarBandPresence ?? 0 }
        titlebarReveal.onStateChange = { [weak self] state in
            self?.collapsedBand.setEngaged(CollapsedBandReveal.isEngaged(state))
        }
        collapsedBand.setEngaged(CollapsedBandReveal.isEngaged(titlebarReveal.state))
    }

    /// How much of the toolbar band shows: the sidebar's on-screen share of
    /// its width (cx-uxdr), or the corner hover's open share over a hidden
    /// sidebar, whichever is larger. Both are animated widths: each frame
    /// lays this view out, so the band and the strip after it move in step,
    /// a change mid-animation retargets from what is on screen, and Reduce
    /// Motion snaps.
    var toolbarBandPresence: CGFloat { max(sidebarBandShare, collapsedBand.presence) }

    /// The sidebar's on-screen share of its width.
    var sidebarBandShare: CGFloat {
        let width = sidebar.model.width
        guard width > 0 else { return sidebar.model.isHidden ? 0 : 1 }
        return min(1, max(0, sidebar.frame.width / width))
    }
}
