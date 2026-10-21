import AppKit
import CmuxNextDesign

// `sidebar.side` (R109): the panel pins to the edge facing the content, so
// a hiding sidebar slides out past the window edge, and the resize handle
// sits on that inner edge.
extension SidebarContainerView {
    static func pins(panel: NSView, clip: NSView) -> [SidebarSide: [NSLayoutConstraint]] {
        [
            .left: [panel.trailingAnchor.constraint(equalTo: clip.trailingAnchor)],
            .right: [panel.leadingAnchor.constraint(equalTo: clip.leadingAnchor)],
        ]
    }

    /// Swaps the pins to `side` without animating.
    func applySide() {
        for (pinSide, constraints) in sidePins where pinSide != side { NSLayoutConstraint.deactivate(constraints) }
        NSLayoutConstraint.activate(sidePins[side] ?? [])
        mountHandle()
        needsLayout = true
    }

    /// The resize band for the current tokens: the pane dividers' hit width, at least
    /// ``SidebarResizeBand/minimumWidth``.
    var resizeBand: SidebarResizeBand {
        SidebarResizeBand(width: max(Metrics.dividerHitWidth, SidebarResizeBand.minimumWidth), gutter: Metrics.mainPaneGutter)
    }

    /// Puts the resize handle in the superview, just above this view, and pins it across the
    /// edge facing the content (`SidebarResizeBand`). Without a superview it waits in this view.
    /// Inside this view its outer part would be clipped from clicks, the cursor and hover; in
    /// the superview it lies over the neighbor without moving any frame (u2255).
    func mountHandle() {
        let host = superview ?? self
        NSLayoutConstraint.deactivate(handleConstraints)
        if handle.superview !== host {
            handle.removeFromSuperview()
            if host === self {
                addSubview(handle)
            } else {
                host.addSubview(handle, positioned: .above, relativeTo: self)
            }
        }
        let band = resizeBand
        mountedBand = band
        handle.edgeOffset = side == .left ? band.inside : band.outside
        handleConstraints = [
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: band.width),
            side == .left ? handle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: band.outside)
                : handle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -band.outside),
        ]
        NSLayoutConstraint.activate(handleConstraints)
    }
}
