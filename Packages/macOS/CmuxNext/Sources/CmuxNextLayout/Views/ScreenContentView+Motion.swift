import AppKit
import CmuxNextDesign
extension ScreenContentView {
    // MARK: Animation
    var hasMotion: Bool {
        if !isUserScrolling && (scroll.value != scroll.target || scroll.velocity != 0) { return true }
        if rowsMoving { return true }
        return paneFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
            || dividerFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
    }
    /// Advances springs by `dt` with the frame's motion `policy`. Returns
    /// true while anything still moves. A screen at rest (a drag frame that
    /// moved nothing, a still pointer) does no work.
    func step(_ dt: Double, policy: MotionPolicy = Motion.policy) -> Bool {
        guard hasMotion || reportScrollOnSettle else { return false }
        var moving = false
        let frameSpring = policy.spring(motionState.frameSpring), appear = policy.spring(.appear)
        // The panes and dividers are one motion: none settles on its own (an edge with a shorter
        // travel would snap frames before the others and change the gap beside it); they all land
        // in the frame the last one comes within a quarter point of rest.
        for key in Array(paneFrames.keys) {
            let token = zoomMotion.spring(for: key, fallback: motionState.frameSpring)
            if paneFrames[key]?.advanceUnsettled(dt, parameters: token == motionState.frameSpring ? frameSpring : policy.spring(token),
                                                 alphaParameters: appear) == true { moving = true }
        }
        for key in Array(dividerFrames.keys) {
            if dividerFrames[key]?.advanceUnsettled(dt, parameters: frameSpring) == true { moving = true }
        }
        if paneFrames.values.allSatisfy(\.geometryNearRest) && dividerFrames.values.allSatisfy(\.geometryNearRest) {
            for key in Array(paneFrames.keys) { paneFrames[key]?.snapGeometry() }
            for key in Array(dividerFrames.keys) { dividerFrames[key]?.snapGeometry() }
        } else {
            moving = true
        }
        if stepRows(dt, policy: policy) { moving = true }
        if MotionTrace.isEnabled { MotionTrace.sample("layout.travel", Double(travelLeft)) }
        if scrollRidesFrames, !paneFrames.values.contains(where: { $0.rect != $0.targetRect }) { scrollRidesFrames = false }
        if !isUserScrolling {
            if scroll.advance(dt, parameters: scrollRidesFrames ? frameSpring : policy.spring(.scroll), epsilon: 0.25) {
                moving = true
                scrollbarFlash = true
            } else if reportScrollOnSettle {
                reportScrollOnSettle = false
                reportLeadingColumn()
            }
        }
        applyPresentation()
        // A zoom that landed in this frame lets go of the panes it covered.
        releaseCovered()
        return moving
    }
    /// A close's first frame of the pane, divider and (riding them) camera springs, in the change
    /// that starts them, once `syncScroll` placed the camera: the frame that drops the closed pane
    /// already shows its neighbours covering some of its space.
    func leadIfPending(_ dt: Double = 1.0 / 120, policy: MotionPolicy = Motion.policy) {
        guard leadsFrame else { return }
        leadsFrame = false
        let frameSpring = policy.spring(motionState.frameSpring), appear = policy.spring(.appear)
        for key in Array(paneFrames.keys) { _ = paneFrames[key]?.advance(dt, parameters: frameSpring, alphaParameters: appear) }
        for key in Array(dividerFrames.keys) { _ = dividerFrames[key]?.advance(dt, parameters: frameSpring) }
        if scrollRidesFrames, !isUserScrolling { _ = scroll.advance(dt, parameters: frameSpring, epsilon: 0.25) }
        applyPresentation()
    }

    /// New dock columns' panes still growing in from their screen edge (their frames).
    var growingDocks: [AnimatedFrame] { PaneArrival.growing(arriving, frames: paneFrames, in: geometry, docks: newDockColumns) }
    /// Lays every pane out at the rect its spring presents this frame (live, as a window resize
    /// is: the host, its tab strip and its terminal or page take that size now), then clips each
    /// host by the docks and by the panes in front of it.
    func applyPresentation() {
        let strip = stripShift, restStrip = geometry.viewShift(offset: isUserScrolling ? scroll.value : scroll.target)
        let uncovered = uncoveredRect, clip = PaneArrival.stripClip(geometry, docks: growingDocks), zooming = zoomMotion.pane
        var clips: [(host: PaneHostView, scrolls: Bool)] = []
        let scale = self.scale
        for (pane, frame) in paneFrames {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            let scrolls = geometry.scrolls(pane: pane)
            if arriving.contains(pane), frame.rect == frame.targetRect { arriving.remove(pane) }
            // On the pixel grid, each edge rounded on its own: two edges a whole number of pixels
            // apart (a pane and the divider beside it, both on the one spring) stay that far apart.
            let placed = frame.rect.pixelEdges(scale).offsetBy(dx: scrolls ? strip : 0, dy: -rowOffset(of: pane))
            // Before the frame moves: chrome that re-checks itself on the move reads the rest.
            let rest = frame.targetRect.offsetBy(dx: scrolls ? restStrip : 0, dy: -rowOffset(of: pane))
            host.restOffset = CGVector(dx: rest.minX - placed.minX, dy: rest.minY - placed.minY)
            if host.frame != placed {
                host.frame = placed
                // Its tab strip and content lay out in this frame's step, with the frame: never a
                // layout pass behind it (`PaneContentView.layout` sizes the strip).
                host.layoutSubtreeIfNeeded()
            }
            (host.alphaValue, host.isDocked) = (frame.alpha.value, !scrolls)
            // The zooming pane is above the docks (`rank`) until it lands: the strip's dock clip does not cut it.
            zoomMotion.track(pane, frame)
            clips.append((host, scrolls && pane != zoomMotion.pane))
        }
        // A zoom that landed gives its pane back its place in the stacking order (`rank`).
        if zoomMotion.pane != zooming { ensureStacking() }
        // Once every frame is placed: a pane is clipped by the panes in front of it, the panes a
        // zoom covers too (they stay where they were, opaque, `zoomMotion.covered`).
        let above = panesAbove()
        for (host, scrolls) in clips { clipToStrip(host, scrolls: scrolls, clip: clip, above: above) }
        for host in coveredHosts { clipToStrip(host, scrolls: false, clip: nil, above: above) }
        for (kind, frame) in dividerFrames {
            guard let view = dividerViews[kind] else { continue }
            let scrolls = self.scrolls(kind)
            view.frame = frame.rect.pixelEdges(scale).offsetBy(dx: scrolls ? strip : 0, dy: -rowOffset(of: kind))
            view.alphaValue = frame.alpha.value
            // A strip divider under a docked column must not take its clicks.
            let hidden = scrolls && !geometry.dock.isEmpty && view.frame.intersection(uncovered).width < 0.5
            if view.isHidden != hidden { view.isHidden = hidden }
        }
        updateScrollbar()
        refreshDividerHover()
        context.overlayNeedsSync()
    }
    /// Divider hover from the pointer and the current frames (`ScreenDividers`).
    func refreshDividerHover() { ScreenDividers(screen: self).refreshHover() }
    /// Hosts this screen displays now: its panes', then those a zoom covers (their rings and
    /// dims stay as they were, under the zooming pane, until it lands).
    var displayedHosts: [PaneHostView] {
        paneFrames.keys.compactMap { pane in
            context.hosts[pane].flatMap { $0.superview === self ? $0 : nil }
        } + coveredHosts
    }

    var coveredHosts: [PaneHostView] {
        covered.compactMap { pane in context.hosts[pane].flatMap { $0.superview === self ? $0 : nil } }
    }
    var dividerMouseAreas: [LayoutMouseArea] { ScreenDividers(screen: self).mouseAreas }
    var dividerLineRects: [CGRect] { ScreenDividers(screen: self).lineRects }
}

extension CGRect {
    /// This rect with each edge on the nearest device pixel (`scale` pixels per point).
    func pixelEdges(_ scale: CGFloat) -> CGRect {
        guard scale > 0 else { return self }
        let minX = (self.minX * scale).rounded() / scale, maxX = (self.maxX * scale).rounded() / scale
        let minY = (self.minY * scale).rounded() / scale, maxY = (self.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
