import AppKit
import CmuxNextDesign

// Pane chrome (focus ring, dim, attention), visibility from the motion plan and hit testing, split out
// of ScreenContentView.swift to keep it under its size budget.
extension ScreenContentView {
    // MARK: Chrome

    /// Focus ring, inactive dim and attention rings. Overlay-only: no pane
    /// frame or inset depends on any of it. `flashAnimated`: motion is allowed for the focus flash
    /// even when the rest of the chrome snaps (a close or a new pane changes the layout's shape in
    /// the same pass that moves focus); nil follows `animated`.
    /// `only`: the panes whose chrome can have changed (a focus move: the pane left and the pane
    /// focused); nil updates every pane of the screen.
    func updateChrome(focused: PaneID?, dimsInactive: Bool, attention: [PaneID: AttentionMark], animated: Bool,
                      flashAnimated: Bool? = nil, only: Set<PaneID>? = nil) {
        let multiple = paneFrames.count > 1
        let style = context.style
        let ringAllowed = (multiple || style.focusRing.showsForSinglePane)
            && style.focusIndicator.marksBorder
            // Pointer and scroll focus should not leave a keyboard-only focus ring behind.
            && context.model.lastFocusSource != .pointer
            && context.model.lastFocusSource != .scroll
        let dim = style.inactiveDim(dimsInactive: dimsInactive)
        let flashes = Self.requestsFocusFlash(enabled: FocusIndicatorTunables.flashOnMove.value, multiple: multiple,
                                              source: context.model.lastFocusSource, animated: flashAnimated ?? animated)
        for pane in only.map({ $0.filter { paneFrames[$0] != nil } }) ?? Array(paneFrames.keys) {
            guard let host = context.hosts[pane] else { continue }
            LayoutRootView.paneChromeUpdates &+= 1
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
                readByEntry: isFocused && context.model.attentionReadByEntry.contains(pane),
                focused: isFocused, flashesFocus: flashes,
                animated: animated
            )
        }
    }

    /// Whether a focus change flashes the ring on its pane (`focus.flashOnMove`): only focus nobody
    /// clicked (a link open, the pane after a close, an agent handoff, all `programmatic`); a
    /// click, scroll or key already shows where focus went. One pane on screen needs no cue, and a
    /// window just opening or motion turned off shows none.
    static func requestsFocusFlash(enabled: Bool, multiple: Bool, source: ColumnFocusSource, animated: Bool) -> Bool {
        enabled && multiple && animated && source == .programmatic
    }

    // MARK: Visibility and hit testing

    /// Panes whose sweep (``displayedSweeps()``) meets the viewport. During a fling on the render server, the
    /// panes it shows on its way to rest too: the strip's viewport is swept over the fling's whole way, and a pane
    /// a row or scroll area fling carries over that fling's whole way (``scrollerFlingReach(of:)``).
    func visiblePanes() -> Set<PaneID> { visiblePanes(displayedSweeps()) }

    /// ``visiblePanes()`` for the sweeps of one pass.
    func visiblePanes(_ sweeps: [PaneID: CGRect]) -> Set<PaneID> {
        var result: Set<PaneID> = []
        let uncovered = flingViewport
        for (pane, frame) in paneFrames where max(frame.alpha.value, frame.alpha.target) > 0.01 {
            guard let sweep = sweeps[pane] else { continue }
            // A strip pane wholly under a docked column is hidden.
            let overlap = sweep.intersection(geometry.scrolls(pane: pane) ? uncovered : bounds)
            if !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 { result.insert(pane) }
        }
        // The panes a zoom covers stay on screen under the zooming pane until it lands (`PaneZoomMotion.covered`),
        // as an animating window occludes nothing in Chromium (`WindowIsAnimated`): their content stays shown, so
        // the zooming pane covers it as it grows instead of the content vanishing at the press (felt 1d).
        if zoomMotion.pane != nil {
            for pane in covered where context.hosts[pane].map({ holds($0) }) == true { result.insert(pane) }
        }
        return result
    }

    /// Panes whose sweep lies within one viewport width of the
    /// viewport on either side (architecture.md 4): visible panes plus the
    /// off-screen columns a short scroll brings in. Their content stays
    /// alive, paused, so scrolling back shows it at once.
    func keepAlivePanes() -> Set<PaneID> { keepAlivePanes(displayedSweeps()) }

    /// ``keepAlivePanes()`` for the sweeps of one pass.
    func keepAlivePanes(_ sweeps: [PaneID: CGRect]) -> Set<PaneID> { KeepAliveBand.panes(displayed: sweeps, viewport: bounds) }

    /// The whole way each pane goes from now to its rest, in local coordinates: its rest with every camera at its
    /// rest, grown by how far each spring that moves it still reaches (``RectExcursion``): its CPU frame spring,
    /// the render-server springs of its plan (``renderTracks``) and the cameras that carry it (the strip's, its row
    /// column's, its scroll area's, and the row or scroll area flings on the render server, ``scrollerFlingReach(of:)``).
    /// Velocity and bounce carry a spring past its rest; the sweep holds that too, so no frame on the way shows a pane
    /// outside it.
    func displayedSweeps() -> [PaneID: CGRect] {
        let policy = Motion.panes.policy, now = renderClockTime
        let camera = cameraSpring(policy: policy), areaSpring = policy.spring(.scroll)
        let strip = isUserScrolling ? Excursion.zero : camera.excursion(of: scrollState.spring).negated
        let scrollersFling = scrollerContainers.values.contains { $0.fling != nil }
        var sweeps: [PaneID: CGRect] = [:]
        for (pane, frame) in paneFrames {
            let scrolls = geometry.scrolls(pane: pane)
            let row = baseGeometry.rowColumnOfPane[pane].flatMap { rowScrolls[$0]?.state }
            let area = baseGeometry.scrollAreaOfPane[pane].flatMap { areaScrolls[$0]?.state }
            let rest = frame.targetRect.offsetBy(dx: (scrolls ? restStripShift : 0) - (area?.restOffset ?? 0), dy: -(row?.restOffset ?? 0))
            var reach = RectExcursion(frame, on: frameSpring(of: pane, policy: policy))
            if let track = renderTracks.panes[pane] { reach.add(track, at: now) }
            if scrolls { reach.x.add(strip) }
            if let area, !area.isGestureActive { reach.x.add(areaSpring.excursion(of: area.spring).negated) }
            if let row, !row.isGestureActive { reach.y.add(camera.excursion(of: row.spring).negated) }
            if scrollersFling, let fling = scrollerFlingReach(of: pane) {
                reach.x.add(fling.x)
                reach.y.add(fling.y)
            }
            sweeps[pane] = reach.sweep(around: rest)
        }
        return sweeps
    }

    /// The strip's view shift with its camera at rest (at the finger while a pan holds it).
    var restStripShift: CGFloat { isUserScrolling ? stripShift : geometry.viewShift(offset: scrollState.spring.target) }

    /// Where strip content shows (``uncoveredRect``) over the whole way of a fling on the render server
    /// (`StripClipContainerView.fling`): the translation it shows now, its rest, and its overshoot.
    private var flingViewport: CGRect {
        let uncovered = uncoveredRect
        guard let fling = stripContainer.fling else { return uncovered }
        let rest = stripContainer.translation, shown = stripContainer.shown
        let reach = fling.spring.excursion(displacement: shown.translation - rest, velocity: shown.velocity)
        return uncovered.union(uncovered.offsetBy(dx: rest + reach.low, dy: 0)).union(uncovered.offsetBy(dx: rest + reach.high, dy: 0))
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
}
