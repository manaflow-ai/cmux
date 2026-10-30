import AppKit
import CmuxNextDesign
extension ScreenContentView {
    // MARK: Animation
    var hasMotion: Bool {
        if !isUserScrolling && (scroll.value != scroll.target || scroll.velocity != 0) { return true }
        if rowsMoving || areasMoving { return true }
        return paneFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
            || dividerFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
    }
    /// Advances springs by `dt` with the frame's motion `policy`. Returns
    /// true while anything still moves. A screen at rest (a drag frame that
    /// moved nothing, a still pointer) does no work.
    func step(_ dt: Double, policy: MotionPolicy = Motion.panes.policy) -> Bool { // perf-hot: 4ms motion-frame
        // A released resize drag ends for the pane contents in the frame its layout lands.
        defer { if resizeGesture == .landing { finishResizeGestureIfLanded() } }
        guard hasMotion || reportScrollOnSettle else {
            scrollRidesFrames = false
            return false
        }
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
        // A close's camera shift (strip and rows) stays on the close spring until it rests, not only while
        // the panes move: closing the last column moves no pane, and a switch to the scroll spring
        // when the panes land changes the curve mid-motion (Lawrence 2026-10-20).
        let cameraSpring = scrollRidesFrames ? frameSpring : policy.spring(.scroll)
        if stepRows(dt, spring: cameraSpring) { moving = true }
        if stepAreas(dt, policy: policy) { moving = true }
        if MotionTrace.isEnabled { MotionTrace.sample("layout.travel", Double(travelLeft)) }
        let panesMoving = paneFrames.values.contains { $0.rect != $0.targetRect }
        // The panes landed: their terminals' grids go to the PTY once, now.
        if holdsGrids, !panesMoving { holdsGrids = false }
        if !isUserScrolling {
            if scroll.advance(dt, parameters: cameraSpring, epsilon: 0.25) {
                moving = true
                scrollbarFlash = true
            } else if reportScrollOnSettle {
                reportScrollOnSettle = false
                reportLeadingColumn()
            }
        }
        if !moving { scrollRidesFrames = false }
        applyPresentation()
        // A zoom that landed in this frame lets go of the panes it covered.
        releaseCovered()
        return moving
    }
    /// A close's first frame of the pane, divider and (riding them) camera springs, the strip's and
    /// each row column's, in the change that starts them, once `syncScroll` placed the camera: the
    /// frame that drops the closed pane already shows its neighbours covering some of its space,
    /// and the shift the close needs (the last column or row closed) already under way.
    func leadIfPending(_ dt: Double = 1.0 / 120, policy: MotionPolicy = Motion.panes.policy) {
        guard leadsFrame else { return }
        leadsFrame = false
        let frameSpring = policy.spring(motionState.frameSpring), appear = policy.spring(.appear)
        // The same springs `step` uses: unsettled (no edge lands alone), each pane on its zoom spring token.
        for key in Array(paneFrames.keys) {
            let token = zoomMotion.spring(for: key, fallback: motionState.frameSpring)
            _ = paneFrames[key]?.advanceUnsettled(dt, parameters: token == motionState.frameSpring ? frameSpring : policy.spring(token),
                                                  alphaParameters: appear)
        }
        for key in Array(dividerFrames.keys) { _ = dividerFrames[key]?.advanceUnsettled(dt, parameters: frameSpring) }
        if scrollRidesFrames {
            if !isUserScrolling { _ = scroll.advance(dt, parameters: frameSpring, epsilon: 0.25) }
            _ = stepRows(dt, spring: frameSpring)
        }
        applyPresentation()
    }

    /// Frame ticks a strip pan keeps after its last event: a trackpad sends about one event per
    /// frame, and a gap of a frame or two must not drop the window's display link (an idle
    /// scheduler drops its link, and the next event would make a new one). About 67 ms at 120 Hz.
    static let panTickTail = 8

    /// Shows a strip pan event: now when this display frame shows no pan yet, else at the frame's
    /// tick (``displayFrameBegan()``), so a burst of events costs one presentation (one layout
    /// pass and commit of the moved panes) per frame. The frame's first event still shows in its
    /// own turn, so a pan of about one event per frame shows each event as soon as before.
    func presentPan() {
        panTicksLeft = Self.panTickTail
        if panPresentedInFrame {
            panPresentationPending = true
        } else {
            panPresentedInFrame = true
            applyPresentation()
        }
        // The tick that opens the next frame (and shows a waiting event).
        context.requestFrames()
    }

    /// A display frame began (the layout's frame tick, before its springs step): the pan events
    /// that waited in the last frame show now. Returns true while a pan in progress keeps the frame
    /// ticks (``panTickTail`` frames after its last event).
    func displayFrameBegan() -> Bool {
        panPresentedInFrame = false
        if panPresentationPending { applyPresentation() }
        guard panTicksLeft > 0, isUserScrolling else {
            panTicksLeft = 0
            return false
        }
        panTicksLeft -= 1
        return true
    }

    /// Sets `frame`'s target (opaque); without animation it snaps there. During a pointer gesture (a divider drag)
    /// only a frame the gesture retargets snaps: a spring already running elsewhere (a close landing in another
    /// column) keeps going (M3). Reduce Motion snaps every frame.
    func place(_ frame: inout AnimatedFrame, at target: CGRect, animated: Bool) {
        let retargeted = frame.targetRect != target
        frame.setTarget(target, alpha: 1)
        if !animated, retargeted || !context.model.isGestureActive || context.reduceMotion { frame.snap() }
    }

    /// New dock columns' panes still growing in from their screen edge (their frames).
    var growingDocks: [AnimatedFrame] { PaneArrival.growing(arriving, frames: paneFrames, in: geometry, docks: newDockColumns) }
    /// Lays every pane out at the rect its spring presents this frame (live, as a window resize
    /// is: the host, its tab strip and its terminal or page take that size now), then clips each
    /// host by the docks and by the panes in front of it.
    ///
    /// Work per frame is O(what changed): a host whose placed frame, alpha, clip and covers are as
    /// they were is not touched, nor is a divider that kept its frame, and a pass that changed
    /// nothing asks for no overlay sync and no hover refresh (`PaneMotionBench`, perf-lead issue 3).
    /// `force`: a structural or style change; everything is re-placed and the overlay syncs.
    func applyPresentation(force: Bool = false) { // perf-hot: 4ms motion-frame
        // Every presentation shows the latest pan: no pan event waits after it.
        panPresentationPending = false
        let strip = stripShift, restStrip = geometry.viewShift(offset: isUserScrolling ? scroll.value : scroll.target)
        let uncovered = uncoveredRect, clip = PaneArrival.stripClip(geometry, docks: growingDocks), zooming = zoomMotion.pane
        var clips: [(host: PaneHostView, scrolls: Bool)] = []
        var changed = force
        let scale = self.scale
        let laysOutNow = window != nil && bounds.width >= 1 && bounds.height >= 1
        for (pane, frame) in paneFrames {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            let scrolls = geometry.scrolls(pane: pane)
            if arriving.contains(pane), frame.rect == frame.targetRect { arriving.remove(pane) }
            // On the pixel grid, each edge rounded on its own: two edges a whole number of pixels
            // apart (a pane and the divider beside it, both on the one spring) stay that far apart.
            let placed = frame.rect.pixelEdges(scale).offsetBy(dx: (scrolls ? strip : 0) - areaOffset(of: pane), dy: -rowOffset(of: pane))
            // Before the frame moves: chrome that re-checks itself on the move reads the rest.
            let rest = frame.targetRect.offsetBy(dx: (scrolls ? restStrip : 0) - areaOffset(of: pane), dy: -rowOffset(of: pane))
            let restOffset = CGVector(dx: rest.minX - placed.minX, dy: rest.minY - placed.minY)
            if host.restOffset != restOffset { host.restOffset = restOffset }
            // A new rest size (a split's new pane has none before its first one) on a running spring.
            let restChanged = host.restSize != rest.size
            if host.restSize != rest.size { host.restSize = rest.size }
            // On a spring until the frame it lands at is laid out (`PaneHostView.isOnLayoutSpring`).
            let springing = frame.rect != frame.targetRect
            if springing { host.isOnLayoutSpring = true }
            defer { if !springing { host.isOnLayoutSpring = false } }
            if host.frame.size != placed.size {
                host.frame = placed
                // Its tab strip and content lay out in this frame's step, with the frame: never a
                // layout pass behind it (`PaneContentView.layout` sizes the strip). Only at a real size in a
                // window: before the root is placed (a new window's content builds its layout first) the
                // frames come from an empty viewport, and laying every pane out there broke Auto Layout
                // constraints in each one (4.77 s for moveWorkspaceToNewWindow in STRESS); the window's
                // layout pass lays them out once the root has its size.
                if laysOutNow, placed.width >= 1, placed.height >= 1 { host.layoutSubtreeIfNeeded() }
                changed = true
            } else if host.frame.origin != placed.origin {
                // A pane that only moves (the strip camera, a column opening beside it) keeps its
                // size: no layout of its strip or content, no terminal resize.
                host.frame = placed
                changed = true
            }
            // A spring that starts or retargets (a press during the motion) to a new size: the content
            // hears the size it will rest at now, once (a terminal sends its final grid at the start).
            if restChanged, springing { host.announceRest() }
            if host.alphaValue != frame.alpha.value {
                host.alphaValue = frame.alpha.value
                changed = true
            }
            if host.isDocked == scrolls { host.isDocked = !scrolls }
            // The zooming pane is above the docks (`rank`) until it lands: the strip's dock clip does not cut it.
            zoomMotion.track(pane, frame)
            clips.append((host, scrolls && pane != zoomMotion.pane))
        }
        // A zoom that landed gives its pane back its place in the stacking order (`rank`).
        if zoomMotion.pane != zooming {
            ensureStacking()
            changed = true
        }
        // Once every frame is placed: a pane is clipped by the panes in front of it, the panes a
        // zoom covers too (they stay where they were, opaque, `zoomMotion.covered`). A host whose
        // clip inputs did not change keeps its clip without recomputing it.
        let above = panesAbove()
        for (host, scrolls) in clips {
            if clipToStrip(host, scrolls: scrolls, clip: clip, above: above, force: force) { changed = true }
        }
        for host in coveredHosts {
            if clipToStrip(host, scrolls: false, clip: nil, above: above, force: force) { changed = true }
        }
        var dividersChanged = force
        for (kind, frame) in dividerFrames {
            guard let view = dividerViews[kind] else { continue }
            let scrolls = self.scrolls(kind)
            let placed = frame.rect.pixelEdges(scale).offsetBy(dx: (scrolls ? strip : 0) - areaOffset(of: kind), dy: -rowOffset(of: kind))
            let shownArea = areaWindow(of: kind), clips: [CGRect?] = [uncovered, shownArea]
            guard force || view.frame != placed || view.alphaValue != frame.alpha.value || view.placedClips != clips else { continue }
            dividersChanged = true
            if view.frame != placed { view.frame = placed }
            if view.alphaValue != frame.alpha.value { view.alphaValue = frame.alpha.value }
            view.placedClips = clips
            // A strip divider under a docked column must not take its clicks, nor one scrolled out of its area.
            let hidden = (scrolls && !geometry.dock.isEmpty && view.frame.intersection(uncovered).width < 0.5)
                || shownArea.map { !$0.contains(CGPoint(x: view.frame.midX, y: view.frame.midY)) } == true
            if view.isHidden != hidden { view.isHidden = hidden }
            // Shown, its cursor and click catcher still stop at a dock and at its area's window.
            var pointerClip: CGRect? = scrolls && !geometry.dock.isEmpty ? uncovered : nil
            if let area = shownArea { pointerClip = pointerClip.map { $0.intersection(area) } ?? area }
            view.cursorClip = pointerClip
        }
        updateScrollbar()
        // A pan with the finger down is layout motion too (hasMotion leaves user gestures out): motion-time content
        // (divider catcher panels, page windows) waits for the landing. The landing frame's advanceFrame clears it.
        let gesturing = isUserScrolling || rowScrolls.values.contains(where: \.state.isGestureActive)
            || areaScrolls.values.contains(where: \.state.isGestureActive)
        if gesturing, changed {
            userMotionActive = true
            context.userMotionStepped()
        } else if !gesturing, userMotionActive {
            // The gesture ended: a fling springs on (advanceFrame ends the motion when it lands), else it ends now.
            userMotionActive = false
            if !hasMotion { context.userMotionEnded() }
        }
        // The handles moved under a still pointer, or the panes did (a zoom covers handles).
        if dividersChanged || changed { refreshDividerHover() }
        if dividersChanged || changed { context.overlayNeedsSync() }
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

extension ScreenContentView {
    /// The local window of the scroll area holding a split divider, if any.
    func areaWindow(of kind: DividerHandleView.Kind) -> CGRect? {
        guard case let .split(id) = kind, let area = baseGeometry.scrollAreaOfSplit[id] else { return nil }
        return displayedAreaWindow(area)
    }
}
