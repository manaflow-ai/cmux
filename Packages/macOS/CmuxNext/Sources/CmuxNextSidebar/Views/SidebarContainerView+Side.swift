public import AppKit
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

    /// How far past the container's content-side edge the sidebar shows: its pane reach plus the
    /// outer half of the border line when it shows at rest.
    /// Hover cards beside a row touch this edge (`sidebarColumnOnScreen`).
    var visibleEdgeOutset: CGFloat {
        guard !handle.isHiddenOrHasHiddenAncestor else { return 0 }
        return visualPaneReach + (handle.restingLineWidth > 0 ? handle.lineWidth / 2 : 0)
    }

    /// Swaps the pins to `side` without animating.
    func applySide() {
        for (pinSide, constraints) in sidePins where pinSide != side { NSLayoutConstraint.deactivate(constraints) }
        NSLayoutConstraint.activate(sidePins[side] ?? [])
        setClipReach(paneReach, collapsed: isPanelCollapsed, animated: false)
        mountHandle()
        needsLayout = true
    }

    /// The resize band for the current tokens: the pane dividers' hit width, at least
    /// ``SidebarResizeBand/minimumWidth``.
    var resizeBand: SidebarResizeBand {
        SidebarResizeBand(width: max(Metrics.dividerHitWidth, SidebarResizeBand.minimumWidth), gutter: max(0, Metrics.mainPaneGutter - paneReach))
    }

    /// The resize band in window coordinates; nil while the handle is hidden or out of a window.
    /// A Chromium page is a child window above this one and would take the mouse there, so the
    /// window covers the band with a catcher panel above pages, as for a pane divider
    /// (`DividerMouseCatchers`).
    public var resizeBandInWindow: CGRect? {
        guard handle.window != nil, !handle.isHiddenOrHasHiddenAncestor, handle.bounds.width > 0 else { return nil }
        return handle.convert(handle.bounds, to: nil)
    }

    /// The catcher panels changed: the handle's hover passes through `windows` and is recomputed,
    /// so it never stays lit after the last page closes under a still pointer.
    public func refreshResizeHover(passThrough windows: @escaping () -> Set<Int>) {
        handle.hoverPassThroughWindows = windows
        handle.refreshHover()
    }

    /// The pointer entered or left the band's catcher panel, so the handle under it got no event:
    /// its hover is recomputed from the pointer (`PointerHover` stays its one owner).
    public func refreshResizeHover() {
        handle.refreshHover()
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
        mountedPaneReach = paneReach
        // Keep the grab target centred on the container's logical edge so the existing hit area
        // stays stable; only the resting line follows the extended surface edge.
        handle.edgeOffset = side == .left ? band.inside + paneReach : band.outside - paneReach
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
