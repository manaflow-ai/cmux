import AppKit
import CmuxNextDesign

// Lawrence (nxdog41): with the sidebar hidden, the window's controls (traffic lights, the titlebar
// band and the incognito badge) collapse at rest, and the top-left strip keeps no room for them, so
// its tabs start at the left edge. They come back while the pointer is over the top-left corner
// (the region covers the traffic lights, so a move straight to Close reveals before the click), or
// while the band has keyboard focus (VoiceOver). Full screen and a shown sidebar never collapse.
// The one hover mechanism (HoverReveal): no timer, no polling. Showing uses the `.appear` timing;
// collapsing uses `.disappear` with a slow-start curve, so a quick pass across the corner reverses
// from where it is instead of flickering.
extension WindowRootView {
    func setUpCornerReveal() {
        cornerReveal.add(toolbarBand.sidebarToggle)
        cornerReveal.onChange = { [weak self] _ in self?.applyCornerReveal() }
        applyCornerReveal()
    }

    /// Whether the controls collapse now (pure).
    static func controlsCollapse(sidebarHidden: Bool, revealed: Bool, fullScreen: Bool) -> Bool {
        sidebarHidden && !revealed && !fullScreen
    }

    func applyCornerReveal() {
        let fullScreen = window?.styleMask.contains(.fullScreen) ?? false
        // A shown sidebar (or full screen) keeps the controls: the reveal is off, so it shows always.
        cornerReveal.isEnabled = sidebarHidden && !fullScreen
        let collapsed = Self.controlsCollapse(sidebarHidden: sidebarHidden, revealed: cornerReveal.isRevealed, fullScreen: fullScreen)
        guard collapsed != windowControlsCollapsed else { return }
        windowControlsCollapsed = collapsed
        let alpha: CGFloat = collapsed ? 0 : 1
        let views: [NSView] = [toolbarBand] + (titlebarBadge.map { [$0] } ?? []) + trafficLightButtons
        let apply = {
            for view in views { view.animator().alphaValue = alpha }
            self.onWindowControlsChange?(collapsed)
        }
        if collapsed { Motion.animateExit(.disappear, in: self, apply) } else { Motion.animateTimed(.appear, in: self, apply) }
    }

    /// The window's close, minimize and zoom buttons.
    var trafficLightButtons: [NSView] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    /// The corner spans the top row from the window's left edge to the band's right edge.
    func layoutCornerReveal(rowHeight: CGFloat) {
        let right = max(toolbarBand.frame.maxX, (titlebarBadge?.isHidden == false ? titlebarBadge?.frame.maxX : nil) ?? 0)
        cornerRegion.frame = CGRect(x: 0, y: bounds.maxY - rowHeight, width: right + Metrics.space3, height: rowHeight)
    }

    /// The corner region's frame in window coordinates (tests, debug).
    var cornerRegionFrameInWindow: CGRect { cornerRegion.convert(cornerRegion.bounds, to: nil) }
}
