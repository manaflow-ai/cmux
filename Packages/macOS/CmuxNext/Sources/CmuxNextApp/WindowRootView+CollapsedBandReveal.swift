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
        collapsedBand.install(in: self, band: toolbarBand)
        collapsedBand.shownPresence = { [weak self] in self?.toolbarBandPresence ?? 0 }
        collapsedBand.reveal = titlebarReveal
        titlebarReveal.onStateChange = { [weak self] state in
            guard let band = self?.collapsedBand else { return }
            band.setEngaged(band.isEngaged(state))
        }
        collapsedBand.setEngaged(collapsedBand.isEngaged(titlebarReveal.state))
    }

    /// How much of the toolbar band shows: the sidebar's on-screen share of
    /// its width (cx-uxdr), or the corner hover's open share over a hidden
    /// sidebar, whichever is larger. The sidebar's is its animated width;
    /// the corner hover's changes once per open or close, and its motion is
    /// a clip on the band's layer (`CollapsedBandReveal`).
    var toolbarBandPresence: CGFloat { max(sidebarBandShare, collapsedBand.presence) }

    /// The sidebar's on-screen share of its width.
    var sidebarBandShare: CGFloat {
        let width = sidebar.model.width
        guard width > 0 else { return sidebar.model.isHidden ? 0 : 1 }
        return min(1, max(0, sidebar.frame.width / width))
    }
}
