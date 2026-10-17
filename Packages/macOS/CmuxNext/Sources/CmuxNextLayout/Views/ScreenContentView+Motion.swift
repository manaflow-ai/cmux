import AppKit
import CmuxNextDesign
extension ScreenContentView {
    // MARK: Animation
    private var hasMotion: Bool {
        if !isUserScrolling && (scroll.value != scroll.target || scroll.velocity != 0) { return true }
        if rowsMoving { return true }
        return zoomMotion.isMoving || paneFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
            || dividerFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
    }
    /// Advances springs by `dt`. Returns true while anything still moves.
    func step(_ dt: Double) -> Bool {
        var moving = false
        for key in Array(paneFrames.keys) {
            if paneFrames[key]?.advance(dt, parameters: Motion.spring(zoomMotion.spring(for: key, fallback: motionState.frameSpring)),
                                        alphaParameters: Motion.spring(.appear)) == true { moving = true }
        }
        if zoomMotion.advance(dt) { moving = true }
        releaseCovered()
        for key in Array(dividerFrames.keys) {
            if dividerFrames[key]?.advance(dt, parameters: Motion.spring(motionState.frameSpring)) == true { moving = true }
        }
        if stepRows(dt) { moving = true }
        if MotionTrace.isEnabled { MotionTrace.sample("layout.travel", Double(travelLeft)) }
        if !isUserScrolling {
            if scroll.advance(dt, parameters: Motion.spring(.scroll), epsilon: 0.25) {
                moving = true
                scrollbarFlash = true
            } else if reportScrollOnSettle {
                reportScrollOnSettle = false
                reportLeadingColumn()
            }
        }
        applyPresentation()
        return moving
    }
    /// New dock columns' panes still growing in from their screen edge (their frames).
    var growingDocks: [AnimatedFrame] { PaneArrival.growing(arriving, frames: paneFrames, in: geometry, docks: newDockColumns) }
    func applyPresentation() {
        let strip = stripShift
        let uncovered = uncoveredRect, clip = PaneArrival.stripClip(geometry, docks: growingDocks)
        var clips: [(host: PaneHostView, scrolls: Bool, revealing: CGRect?)] = []
        for (pane, frame) in paneFrames {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            let scrolls = geometry.scrolls(pane: pane)
            let shift = CGVector(dx: scrolls ? strip : 0, dy: -rowOffset(of: pane))
            if arriving.contains(pane), frame.rect == frame.targetRect { arriving.remove(pane) }
            if heldFrames[pane] != nil, frame.rect == frame.targetRect { heldFrames[pane] = nil }
            let held = heldFrames[pane]
            // The zooming pane keeps its full size under its spring rect (`PaneZoomMotion`); an arriving
            // pane slides in at its final size; a held one keeps its frame. Each shows only the presented
            // rect (a split's: the padded content, rounded as at rest).
            let zoomed = zoomMotion.presentation(of: pane, frame)
            let revealing = zoomed != nil ? frame.rect.offsetBy(dx: shift.dx, dy: shift.dy)
                : arriving.contains(pane) || held != nil
                ? SplitMotion.visible(frame.rect, padding: host.padding).offsetBy(dx: shift.dx, dy: shift.dy) : nil
            let placed = (zoomed ?? held ?? (arriving.contains(pane) ? PaneArrival.presentation(shown: frame.rect, target: frame.targetRect) : frame.rect))
                .offsetBy(dx: shift.dx, dy: shift.dy)
            if host.frame != placed { host.frame = placed }
            (host.alphaValue, host.isDocked, host.revealRect) = (frame.alpha.value, !scrolls, revealing)
            clips.append((host, scrolls, revealing))
        }
        // Once every frame is placed: a pane is clipped by the panes in front of it.
        for (host, scrolls, revealing) in clips { clipToStrip(host, scrolls: scrolls, clip: clip, revealing: revealing) }
        for (pane, alpha) in zoomMotion.opacities {
            if let host = context.hosts[pane], host.superview === self { host.alphaValue = alpha; clipToStrip(host, scrolls: false, clip: nil) }
        }
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
    /// Hosts this screen displays now.
    var displayedHosts: [PaneHostView] {
        paneFrames.keys.compactMap { pane in
            context.hosts[pane].flatMap { $0.superview === self ? $0 : nil }
        }
    }
    var dividerMouseAreas: [LayoutMouseArea] { ScreenDividers(screen: self).mouseAreas }
    var dividerLineRects: [CGRect] { ScreenDividers(screen: self).lineRects }
}
