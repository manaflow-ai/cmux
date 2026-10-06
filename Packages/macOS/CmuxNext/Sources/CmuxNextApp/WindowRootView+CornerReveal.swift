import AppKit
import CmuxNextDesign

// Window chrome is stable across sidebar visibility, hover, focus, and full-screen transitions.
// The corner reveal remains as a pointer-tracking seam for hover styling, but never removes room
// for or fades the traffic lights, toolbar band, or titlebar badge.
extension WindowRootView {
    func setUpCornerReveal() {
        toolbarBand.sidebarToggle.alphaValue = 1
        cornerReveal.onChange = { [weak self] _ in self?.applyCornerReveal() }
        applyCornerReveal()
    }

    /// Window chrome remains mounted regardless of sidebar or pointer state.
    static func controlsCollapse(sidebarHidden: Bool, revealed: Bool, fullScreen: Bool) -> Bool {
        false
    }

    func applyCornerReveal() {
        // Window chrome is stable. Sidebar visibility changes the content
        // layout, never whether the traffic lights and toolbar exist.
        cornerReveal.isEnabled = false
        let collapsed = false
        guard collapsed != windowControlsCollapsed else { return }
        windowControlsCollapsed = collapsed
        let views: [NSView] = [toolbarBand] + (titlebarBadge.map { [$0] } ?? []) + trafficLightButtons
        let apply = {
            for view in views { view.animator().alphaValue = 1 }
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
