import AppKit
import CmuxNextDesign

// Pane chrome (focus ring, dim, attention), visibility and hit testing, and
// the travel a split has left (debug.motion), split out of
// ScreenContentView.swift to keep it under its size budget.
extension ScreenContentView {
    // MARK: Chrome

    /// Focus ring, inactive dim and attention rings. Overlay-only: no pane
    /// frame or inset depends on any of it.
    func updateChrome(focused: PaneID?, dimsInactive: Bool, attention: [PaneID: AttentionMark], animated: Bool) {
        let multiple = paneFrames.count > 1
        let style = context.style
        let ringAllowed = (multiple || style.focusRing.showsForSinglePane)
            && style.focusIndicator.marksBorder
            // Pointer and scroll focus should not leave a keyboard-only focus ring behind.
            && context.model.lastFocusSource != .pointer
            && context.model.lastFocusSource != .scroll
        let dim = style.inactiveDim(dimsInactive: dimsInactive)
        for pane in paneFrames.keys {
            guard let host = context.hosts[pane] else { continue }
            let isFocused = pane == focused
            host.setChrome(
                showsRing: ringAllowed && isFocused,
                dim: multiple && !isFocused ? dim.amount : 0, dimFill: dim.fill,
                focusRing: style.focusRing,
                ringAlphaOverride: style.focusRingAlphaOverride,
                tabEmphasis: .forPane(isFocused: isFocused, paneCount: paneFrames.count, indicator: style.focusIndicator,
                                      style: style.inactiveTabStyle, strength: style.inactiveTabStrength),
                border: PaneOverlayView.Border(shows: style.showsPaneBorder, width: style.paneBorderWidth, color: style.paneBorderColor),
                attention: attention[pane],
                attentionSettings: style.attention,
                animated: animated
            )
        }
    }

    // MARK: Visibility and hit testing

    /// Panes whose displayed frame intersects the viewport.
    func visiblePanes() -> Set<PaneID> {
        var result: Set<PaneID> = []
        let uncovered = uncoveredRect
        for (pane, frame) in paneFrames {
            // A strip pane wholly under a docked column is hidden.
            let scrolls = geometry.scrolls(pane: pane)
            let displayed = displayedRect(frame.rect, pane: pane)
            let overlap = displayed.intersection(scrolls ? uncovered : bounds)
            if !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5, frame.alpha.value > 0.01 {
                result.insert(pane)
            }
        }
        return result
    }

    /// Panes whose displayed frame lies within one viewport width of the
    /// viewport on either side (architecture.md 4): visible panes plus the
    /// off-screen columns a short scroll brings in. Their content stays
    /// alive, paused, so scrolling back shows it at once.
    func keepAlivePanes() -> Set<PaneID> {
        KeepAliveBand.panes(displayed: paneFrames.reduce(into: [:]) { $0[$1.key] = displayedRect($1.value.rect, pane: $1.key) },
                            viewport: bounds)
    }

    /// The pane under `localPoint`: a docked column's pane above the strip.
    func pane(at localPoint: NSPoint) -> PaneID? {
        // Canvas panes overlap: the front-most one under the point.
        if let canvas = canvasState.canvas { return canvas.pane(at: localPoint) }
        // A pane scrolled out of its scroll area's window takes no click there.
        func shown(_ pane: PaneID) -> Bool { displayedAreaWindow(of: pane)?.contains(localPoint) ?? true }
        if geometry.dock.contains(where: { $0.cover.contains(localPoint) }) {
            return geometry.panes.first { !geometry.scrolls(pane: $0.key) && $0.value.contains(localPoint) && shown($0.key) }?.key
        }
        let content = CGPoint(x: localPoint.x - stripShift, y: localPoint.y)
        return geometry.panes.first { geometry.scrolls(pane: $0.key) && $0.value.contains(content) && shown($0.key) }?.key
    }

    /// Displayed frame of `pane` in local coordinates: its host's frame (on the pixel grid, `applyPresentation`).
    func displayedFrame(of pane: PaneID) -> CGRect? {
        paneFrames[pane].map { displayedRect($0.rect.pixelEdges(scale), pane: pane) }
    }

    // MARK: Motion trace

    /// The points every pane and divider still has to travel (all four
    /// edges): the layout spring's path, sampled per frame for debug.motion.
    var travelLeft: CGFloat {
        func left(_ frame: AnimatedFrame) -> CGFloat {
            abs(frame.x.target - frame.x.value) + abs(frame.y.target - frame.y.value)
                + abs(frame.width.target - frame.width.value) + abs(frame.height.target - frame.height.value)
        }
        return paneFrames.values.reduce(0) { $0 + left($1) } + dividerFrames.values.reduce(0) { $0 + left($1) }
    }
}
