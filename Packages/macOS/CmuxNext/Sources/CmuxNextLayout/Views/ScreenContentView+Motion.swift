import AppKit
import CmuxNextDesign
extension ScreenContentView {
    // MARK: Motion backends

    /// This screen's render-server motion variants, one per kind, in the order their motions start
    /// (the screen's kinds: ``RenderMotionKind``). A task that moves a kind to the render server writes
    /// its variant in its own file and adds its one line here; a kind not listed, or every kind while
    /// `motion.renderServer` is off (the default), steps on the main thread in ``step(_:policy:)``.
    static var renderServerMotions: [any RenderServerMotion<ScreenContentView>] { [SplitRenderMotion(), ZoomRenderMotion(), CanvasRenderMotion()] }

    /// What an open change turn held back from ``applyPresentation(force:)``.
    struct HeldPresentation {
        var force = false
    }

    /// Opens a change turn: a model update, a resize, or a camera move from the scrollbar or the
    /// wheel. With render-server variants live, presentation waits for ``endMotionTurn(needsFrames:policy:)``,
    /// so they take their motions before anything is laid out and the turn lays out once.
    func beginMotionTurn() {
        motionTurnDepth += 1
        if motionTurnDepth == 1, motionBackends.isLive { heldPresentation = HeldPresentation() }
    }

    /// Ends a change turn, after every motion it starts has started (the root's layout, focus, center
    /// and reveal requests, the canvas camera): the render-server kinds take theirs, a close the CPU
    /// keeps takes its first frame (``leadIfPending(_:policy:)``), and the screen lays out once.
    /// Returns whether the CPU still needs display frames: `needsFrames`, less the motions the render
    /// server took.
    @discardableResult
    func endMotionTurn(needsFrames: Bool, policy: MotionPolicy = Motion.panes.policy) -> Bool {
        motionTurnDepth -= 1
        guard motionTurnDepth == 0 else { return needsFrames }
        let held = heldPresentation
        heldPresentation = nil
        let taken = motionBackends.begin(on: self, policy: policy)
        renderTracks.tookBack = false
        // The render server runs the close: it has no first frame on the CPU.
        if taken.contains(.splitClose) { leadsFrame = false }
        let led = leadIfPending(policy: policy)
        if led || held != nil { applyPresentation(force: held?.force ?? false) }
        guard !taken.isEmpty else { return needsFrames }
        return needsFrames && (hasMotion || reportScrollOnSettle || canvasState.camera.isMoving)
    }

    /// `change` as one change turn; returns whether the CPU needs display frames for it.
    @discardableResult
    func motionTurn(_ change: () -> Bool) -> Bool {
        beginMotionTurn()
        return endMotionTurn(needsFrames: change())
    }

    // MARK: Animation
    /// The spring ``step(_:policy:)`` moves `pane`'s frame on: its zoom's token, else the change's frame spring.
    func frameSpring(of pane: PaneID, policy: MotionPolicy) -> SpringParameters {
        policy.spring(zoomMotion.spring(for: pane, fallback: motionState.frameSpring))
    }
    /// The spring ``step(_:policy:)`` moves the strip camera and each row column's on: a close's frame spring
    /// while the camera rides it (``scrollRidesFrames``), else the scroll spring.
    func cameraSpring(policy: MotionPolicy) -> SpringParameters {
        policy.spring(scrollRidesFrames ? motionState.frameSpring : .scroll)
    }
    /// Motion the CPU steps: a fling on the render server is not (the reducer's spring rests on its target).
    var hasMotion: Bool {
        let camera = scrollState.spring
        if !isUserScrolling && (camera.value != camera.target || camera.velocity != 0) { return true }
        if rowsMoving || areasMoving { return true }
        return paneFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
            || dividerFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
    }
    /// The panes the next ``step(_:policy:)`` moves (`motion.frame`'s `arg0`, read only while something takes
    /// `motion` signposts): every pane while a camera that carries them all springs (the strip's scroll, a row
    /// column's or scroll area's, the canvas camera), else the panes whose own frame springs or fades.
    var movingPaneCount: Int {
        let camerasMove = (!isUserScrolling && (scroll.value != scroll.target || scroll.velocity != 0)) || rowsMoving || areasMoving
            || canvasState.camera.isMoving
        if camerasMove { return paneFrames.count }
        return paneFrames.values.count { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
    }
    /// Advances springs by `dt` with the frame's motion `policy`. Returns
    /// true while anything still moves. A screen at rest (a drag frame that
    /// moved nothing, a still pointer) does no work.
    func step(_ dt: Double, policy: MotionPolicy = Motion.panes.policy) -> Bool { // perf-hot: 4ms motion-frame
        // The canvas camera, when the main thread steps it (not on the render server: `CanvasRenderMotion`).
        let cameraMoving = stepCanvasCamera(dt, policy: policy)
        guard hasMotion || reportScrollOnSettle else {
            // A close on the render server keeps the camera on its spring until it lands (`renderSpringLanded`).
            if renderClose == nil { scrollRidesFrames = false }
            return cameraMoving
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
        if MotionTrace.isEnabled { MotionTrace.sample("layout.travel", Double(panePlacement.travelLeft + dividerPlacement.travelLeft)) }
        let panesMoving = paneFrames.values.contains { $0.rect != $0.targetRect }
        // The panes landed: their terminals' grids go to the PTY once, now.
        if holdsGrids, !panesMoving { holdsGrids = false }
        if !isUserScrolling {
            if scrollState.spring.advance(dt, parameters: cameraSpring, epsilon: 0.25) {
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
        return moving || cameraMoving
    }
    /// A close's first frame of the pane, divider and (riding them) camera springs, the strip's and
    /// each row column's, at the end of the change turn that starts them, once `syncScroll` placed
    /// the camera: the frame that drops the closed pane already shows its neighbours covering some
    /// of its space, and the shift the close needs (the last column or row closed) already under way.
    /// Steps only; returns true when it stepped, and the turn presents the result
    /// (``endMotionTurn(needsFrames:policy:)``).
    func leadIfPending(_ dt: Double = 1.0 / 120, policy: MotionPolicy = Motion.panes.policy) -> Bool {
        guard leadsFrame else { return false }
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
            if !isUserScrolling { _ = scrollState.spring.advance(dt, parameters: frameSpring, epsilon: 0.25) }
            _ = stepRows(dt, spring: frameSpring)
        }
        return true
    }

    /// Shows a strip pan event: now when this display frame shows no pan yet, else at the frame's
    /// tick (``displayFrameBegan(at:)``), so a burst of events costs one presentation (one layout
    /// pass and commit of the moved panes) per frame. The frame's first event still shows in its
    /// own turn, so a pan of about one event per frame shows each event as soon as before.
    func presentPan() {
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
    /// that waited in the last frame show now. Returns true while a pan that moves the frames keeps
    /// the frame ticks: until its finger lifts, so a gap of a frame or two between trackpad events
    /// never drops the window's display link (an idle scheduler drops its link, and the next event
    /// would make a new one). A pan on the strip container (``panBase``) shows each event in its own
    /// turn and keeps none, unless it is resampled: then this frame shows it at `frameTime`
    /// (``presentFramePan(at:)``) and the ticks run until the finger lifts.
    func displayFrameBegan(at frameTime: TimeInterval? = nil) -> Bool {
        panPresentedInFrame = false
        if panPresentationPending { applyPresentation() }
        presentFramePan(at: frameTime)
        return isUserScrolling && (panBase == nil || scrollState.resamplesPan)
    }

    /// New dock columns' panes still growing in from their screen edge (their frames).
    var growingDocks: [AnimatedFrame] { PaneArrival.growing(arriving, frames: paneFrames, in: geometry, docks: newDockColumns) }
    /// Lays every pane out at the rect its spring presents this frame (live, as a window resize
    /// is: the host, its tab strip and its terminal or page take that size now). The strip container
    /// clips the strip beside the docks; a host has a clip of its own only in a scroll area or while a
    /// zoom lifts the container over it. The zooming pane has a resting pane's material (no fill): every other
    /// pane is cut where it shows over them (``zoomCover``), felt 1d.
    ///
    /// Work per frame is O(what changed): a host whose placed frame, alpha and clip are as
    /// they were is not touched, nor is a divider that kept its frame, and a pass that changed
    /// nothing asks for no overlay sync and no hover refresh (`PaneMotionBench`, perf-lead issue 3).
    /// `force`: a structural or style change; everything is re-placed and the overlay syncs.
    func applyPresentation(force: Bool = false) { // perf-hot: 4ms motion-frame
        // An open change turn lays out once, at its end (``endMotionTurn(needsFrames:policy:)``).
        if var held = heldPresentation {
            held.force = held.force || force
            heldPresentation = held
            return
        }
        // Every presentation shows the latest pan: no pan event waits after it.
        panPresentationPending = false
        // A pan on the strip container keeps the strip laid out at its base; anything else lays it out at
        // the camera, and the container's translation goes back to zero (``presentPanOnContainer()``).
        if panBase != nil, !(isUserScrolling && pansOnContainer) { panBase = nil }
        // The same for a row or scroll area pan on its container (``prepareScrollerLayout()``).
        prepareScrollerLayout()
        let layoutOffset = self.layoutOffset
        laidOutStripOffset = layoutOffset
        let strip = geometry.viewShift(offset: layoutOffset)
        let restStrip = isUserScrolling ? strip : geometry.viewShift(offset: scrollState.spring.target)
        // Only a dock the CPU grows in moves the strip's range: with none, the range is the rest one.
        let docks = growingDocks
        let uncovered = uncoveredRect, clip = docks.isEmpty ? restStripRange : stripRange(in: geometry, beside: docks)
        let zooming = zoomMotion.pane
        var placedHosts: [PaneHostView] = []
        var changed = force
        // The container shows the camera (a resampled pan's frame offset); a fling on the render server owns it until it lands.
        let translation = geometry.viewShift(offset: shownCameraOffset) - strip
        if stripContainer.fling == nil, stripContainer.translation != translation {
            stripContainer.setTranslation(translation)
            changed = true
        }
        let scale = self.scale
        let laysOutNow = window != nil && bounds.width >= 1 && bounds.height >= 1
        for (pane, frame) in paneFrames {
            guard let host = context.hosts[pane], holds(host) else { continue }
            let scrolls = geometry.scrolls(pane: pane)
            if arriving.contains(pane), frame.rect == frame.targetRect { arriving.remove(pane) }
            let placed = shownRect(frame.rect, of: pane, strip: strip, scale: scale)
            // Before the frame moves: chrome that re-checks itself on the move reads the rest.
            let rest = frame.targetRect.offsetBy(dx: (scrolls ? restStrip : 0) - areaLayoutOffset(of: pane), dy: -rowLayoutOffset(of: pane))
            let restOffset = CGVector(dx: rest.minX - placed.minX, dy: rest.minY - placed.minY)
            if host.restOffset != restOffset { host.restOffset = restOffset }
            // A new rest size (a split's new pane has none before its first one) on a running spring.
            let restChanged = host.restSize != rest.size
            if host.restSize != rest.size { host.restSize = rest.size }
            // On a spring until the frame it lands at is laid out (`PaneHostView.isOnLayoutSpring`).
            let springing = frame.rect != frame.targetRect || host.isOnRenderSpring
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
                // sync-layout: the strip and content commit with this frame's step, never a pass behind it.
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
            // The zooming pane is above the docks (`rank`, its container lifted) until it lands.
            zoomMotion.track(pane, frame)
            placedHosts.append(host)
        }
        // A zoom that landed gives its pane back its place in the stacking order (`rank`).
        if zoomMotion.pane != zooming {
            ensureStacking()
            changed = true
        }
        // The strip's clip beside docked columns is the strip container's bounds: one frame, set only
        // when the range moved (a dock growing in) or a zoom lifts it, whatever the panes in it do.
        // Panes in front (docks, a zoom) are above in the layer tree; a pane has a clip of its own only
        // in a scroll area, or under a zooming pane while the container is lifted (still, so set once).
        if placeStripContainer(clip) {
            changed = true
            context.stripClipsDidChange()
        }
        // The rows' and scroll areas' containers: their range, an area's clip, and the translation a pan shows.
        if placeScrollerContainers(strip: strip) { changed = true }
        if applyZoomCovers(placedHosts + coveredHosts, force: force) { changed = true }
        if changed { coverVersion &+= 1 }
        // A page in its own window under a zooming pane leaves out what that pane covers
        // (`ChildWindowPageFallback`): it re-reads its clip when the panes over it moved.
        if changed, zoomMotion.pane != nil || !covered.isEmpty { context.stripClipsDidChange() }
        let dividersChanged = ScreenDividers(screen: self).place(strip: strip, scale: scale, uncovered: uncovered, force: force)
        updateScrollbar()
        // A pan with the finger down is layout motion too (hasMotion leaves user gestures out): motion-time content
        // (divider catcher panels, page windows) waits for the landing. The landing frame's advanceFrame clears it.
        let gesturing = isGesturing
        if gesturing, changed {
            userMotionActive = true
            context.userMotionStepped()
        } else if !gesturing, userMotionActive, renderSpringsInFlight == 0, !panFlingsInFlight {
            // The gesture ended: a fling springs on (advanceFrame ends the motion when it lands), else it ends now.
            // Render-server springs still running end it at their landing (`renderSpringLanded`).
            userMotionActive = false
            if !hasMotion { context.userMotionEnded() }
        }
        // The handles moved under a still pointer, or the panes did (a zoom covers handles).
        if dividersChanged || changed { refreshDividerHover() }
        if dividersChanged || changed { context.overlayNeedsSync() }
    }
    /// A pan of the strip, a row column or a scroll area has its finger down.
    var isGesturing: Bool {
        isUserScrolling || rowScrolls.values.contains(where: \.state.isGestureActive)
            || areaScrolls.values.contains(where: \.state.isGestureActive)
    }

    /// Where a pane's spring rect `rect` is laid out in this view with the strip camera at `strip`: on the
    /// pixel grid, each edge rounded on its own (two edges a whole number of pixels apart, a pane and the
    /// divider beside it on the one spring, stay that far apart), less its scroll area's and its row column's
    /// offsets as laid out (a pan on their container shows the rest, ``rowLayoutOffset(of:)``).
    func shownRect(_ rect: CGRect, of pane: PaneID, strip: CGFloat, scale: CGFloat) -> CGRect {
        rect.pixelEdges(scale).offsetBy(dx: (geometry.scrolls(pane: pane) ? strip : 0) - areaLayoutOffset(of: pane), dy: -rowLayoutOffset(of: pane))
    }

    /// Where a divider's spring rect `rect` is laid out in this view with the strip camera at `strip`.
    func shownRect(_ rect: CGRect, of kind: DividerHandleView.Kind, strip: CGFloat, scale: CGFloat) -> CGRect {
        rect.pixelEdges(scale).offsetBy(dx: (scrolls(kind) ? strip : 0) - areaLayoutOffset(of: kind), dy: -rowLayoutOffset(of: kind))
    }

    /// Divider hover from the pointer and the current frames (`ScreenDividers`); `event` is a
    /// handle's enter or exit, read for its point.
    func refreshDividerHover(at event: NSEvent? = nil) { ScreenDividers(screen: self).refreshHover(at: event) }
    /// Hosts this screen displays now: its panes', then those a zoom covers (their rings and
    /// dims stay as they were, under the zooming pane, until it lands).
    var displayedHosts: [PaneHostView] {
        paneFrames.keys.compactMap { pane in
            context.hosts[pane].flatMap { holds($0) ? $0 : nil }
        } + coveredHosts
    }

    /// Where the pane a zoom or an unzoom moves shows now (this view's coordinates, ``coverFrame(_:)``: on the render
    /// server, all it springs across), while it moves; nil otherwise. The panes under it are cut there
    /// (`PaneHostView.setStripClip(_:cover:)`), as Chrome's compositor draws nothing under an opaque layer and cmux's
    /// panes have no fill of their own: the zooming pane keeps a resting pane's material (felt 1d, Lawrence
    /// 2026-10-29), and the window's art shows through it as it does through every pane.
    var zoomCover: CGRect? {
        guard let pane = zoomMotion.pane, let host = context.hosts[pane], holds(host) else { return nil }
        let shown = coverFrame(host)
        return shown.isNull || shown.isEmpty ? nil : shown
    }

    /// Each host's own clip (``clipToStrip(_:fronts:cover:force:)``) with what a zooming pane shows over it cut out
    /// (``zoomCover``): nothing under the zooming pane shows through it (its padding, corners, header and
    /// translucent content), so it keeps a resting pane's material. A page in its own window (a child window, over
    /// every view of the window) stays shown and is cut the same way: a clip change asks the window's pages to read
    /// their clip again in this turn (`context.stripClipsDidChange`), and its cutouts are the zooming pane's frame now
    /// (`PaneHostView.pageCovers`, ``panes(inFrontOf:)``), so it shows what is uncovered of it in every frame, never a
    /// blank tab (felt 1d: "all the tabs are perfectly visible"). Returns whether a clip changed.
    @discardableResult
    func applyZoomCovers(_ hosts: [PaneHostView], force: Bool) -> Bool {
        let fronts = liftedFronts, cover = zoomCover
        var changed = false
        for host in hosts where clipToStrip(host, fronts: fronts, cover: cover, force: force) { changed = true }
        return changed
    }

    var coveredHosts: [PaneHostView] {
        covered.compactMap { pane in context.hosts[pane].flatMap { holds($0) ? $0 : nil } }
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
    /// The local window of the scroll area holding a split divider, if any, as laid out with the strip
    /// camera at `strip` (``laidOutAreaWindow(_:strip:)``).
    func areaWindow(of kind: DividerHandleView.Kind, strip: CGFloat) -> CGRect? {
        guard case let .split(id) = kind, let area = baseGeometry.scrollAreaOfSplit[id] else { return nil }
        return laidOutAreaWindow(area, strip: strip)
    }
}
