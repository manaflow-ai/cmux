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
        for key in Array(paneFrames.keys) {
            let token = zoomMotion.spring(for: key, fallback: motionState.frameSpring)
            if paneFrames[key]?.advance(dt, parameters: token == motionState.frameSpring ? frameSpring : policy.spring(token),
                                        alphaParameters: appear) == true { moving = true }
        }
        for key in Array(dividerFrames.keys) {
            if dividerFrames[key]?.advance(dt, parameters: frameSpring) == true { moving = true }
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
    func applyPresentation() {
        let strip = stripShift, restStrip = geometry.viewShift(offset: isUserScrolling ? scroll.value : scroll.target)
        let uncovered = uncoveredRect, clip = PaneArrival.stripClip(geometry, docks: growingDocks), zooming = zoomMotion.pane
        var clips: [(host: PaneHostView, scrolls: Bool, revealing: CGRect?)] = []
        for (pane, frame) in paneFrames {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            let scrolls = geometry.scrolls(pane: pane)
            let shift = CGVector(dx: scrolls ? strip : 0, dy: -rowOffset(of: pane))
            if arriving.contains(pane), frame.rect == frame.targetRect { arriving.remove(pane) }
            if heldFrames[pane] != nil, frame.rect == frame.targetRect { heldFrames[pane] = nil }
            let held = heldFrames[pane].map { SplitMotion.placed(held: $0, shown: frame.rect) }
            // The zooming pane keeps its full size under its spring rect (`PaneZoomMotion`); an arriving
            // pane slides in at its final size; a held one keeps its frame. Each shows only the presented
            // rect (a split's: the padded content, rounded as at rest).
            let zoomed = zoomMotion.presentation(of: pane, frame)
            let revealing = zoomed != nil ? frame.rect.offsetBy(dx: shift.dx, dy: shift.dy)
                : arriving.contains(pane) || held != nil
                ? SplitMotion.visible(frame.rect, padding: host.padding).offsetBy(dx: shift.dx, dy: shift.dy) : nil
            let placed = (zoomed ?? held ?? (arriving.contains(pane) ? PaneArrival.presentation(shown: frame.rect, target: frame.targetRect) : frame.rect))
                .offsetBy(dx: shift.dx, dy: shift.dy)
            // Before the frame moves: chrome that re-checks itself on the move reads the rest.
            let rest = frame.targetRect.offsetBy(dx: scrolls ? restStrip : 0, dy: shift.dy)
            host.restOffset = CGVector(dx: rest.minX - placed.minX, dy: rest.minY - placed.minY)
            if host.frame != placed { host.frame = placed }
            (host.alphaValue, host.isDocked, host.revealRect) = (frame.alpha.value, !scrolls, revealing)
            // The zooming pane's ring and border trace its spring rect; the strip's dock clip does not cut it.
            host.chromeFrame = zoomed != nil ? revealing : nil
            clips.append((host, scrolls && zoomed == nil, revealing))
        }
        // A zoom that landed gives its pane back its place in the stacking order (`rank`).
        if zoomMotion.pane != zooming { ensureStacking() }
        // Once every frame is placed: a pane is clipped by the panes in front of it, the panes a
        // zoom covers too (they stay where they were, opaque, `zoomMotion.covered`).
        let above = panesAbove()
        for (host, scrolls, revealing) in clips { clipToStrip(host, scrolls: scrolls, clip: clip, revealing: revealing, above: above) }
        for host in coveredHosts { clipToStrip(host, scrolls: false, clip: nil, above: above) }
        for (kind, frame) in dividerFrames {
            guard let view = dividerViews[kind] else { continue }
            let scrolls = self.scrolls(kind)
            view.frame = frame.rect.offsetBy(dx: scrolls ? strip : 0, dy: -rowOffset(of: kind))
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
