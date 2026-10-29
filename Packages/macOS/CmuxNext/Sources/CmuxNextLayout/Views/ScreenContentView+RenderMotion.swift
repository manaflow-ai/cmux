import AppKit
import CmuxNextDesign
import QuartzCore

/// A split or a close on the render server (chrome-parity R2; on with
/// `motion.renderServer`). In the change's turn every pane and divider the change moves goes to its rest
/// frame once, each resized pane laid out once at its rest size after its content heard that size, and
/// Core Animation shows each one springing there from where it showed, at the velocity it had, on the
/// change's spring token. The main thread does no work per motion frame: Chromium's compositor owns its
/// threaded animations the same way (`cc/animation/animation_host.h`, `cc/animation/keyframe_model.h`),
/// and Core Animation also animates position and bounds on the render server
/// (plans/cmux-next/chrome-parity/p03-rendering.md, section 1.3).
struct SplitRenderMotion: RenderServerMotion {
    var kind: RenderMotionKind { .splitClose }

    func begin(on screen: ScreenContentView, policy: MotionPolicy) -> MotionBackend {
        screen.springSplitOnRenderServer() || screen.springCloseOnRenderServer() ? .renderServer : .cpuStep
    }
}

/// A zoom or an unzoom (Cmd-Shift-Enter) on the render server (chrome-parity R2; on with
/// `motion.renderServer`): the zooming pane goes to its rest frame in the key's turn, laid out once at its
/// rest size, and Core Animation shows it springing there on the zoom token (`PaneZoomMotion`). It stays
/// above the docks until it lands through the `rank` that `reconcile` gives it, not the layer zPosition the
/// task spec names. A click during the spring goes to the pane drawn under the pointer
/// (`ScreenContentView+HitTest.swift`), not to the one whose rest frame holds it. The panes it covers stay untouched under it; their rings, dims and page cutouts leave out all the
/// pane springs across (``ScreenContentView/coverFrame(_:)``), and the landing restores the stacking and lets
/// them go once. Chromium runs a transform animation of a layer that keeps its place in the paint order the
/// same way (`cc/animation/keyframe_model.h`, `cc/trees/property_tree.h`).
struct ZoomRenderMotion: RenderServerMotion {
    var kind: RenderMotionKind { .zoom }

    func begin(on screen: ScreenContentView, policy: MotionPolicy) -> MotionBackend {
        screen.springZoomOnRenderServer() ? .renderServer : .cpuStep
    }
}

extension ScreenContentView {
    /// The render-server springs still carrying this screen's panes and dividers (``RenderSpringTrack``),
    /// in the screen's coordinates.
    struct RenderTracks {
        var panes: [PaneID: RenderSpringTrack] = [:]
        var dividers: [DividerHandleView.Kind: RenderSpringTrack] = [:]
        /// The strip container's bounds spring with a dock growing in (``springStripContainer(from:velocity:on:landed:)``).
        var strip = false
        /// The panes still growing in when the render server took them (``ScreenContentView/arriving``): their
        /// frames rest in the model, so the CPU's next presentation drops them from `arriving`, and a take-back
        /// puts them back, so a dock growing in still moves the strip's range from where it shows.
        var arriving: Set<PaneID> = []
        /// This change turn took the springs back to the CPU frames (``takeRenderSpringsBack()``): the render
        /// server may take the motion again at the turn's end (``springSplitOnRenderServer()``).
        var tookBack = false

        var isEmpty: Bool { panes.isEmpty && dividers.isEmpty && !strip }
    }

    /// A close on the render server that has not landed: the camera rides its frame spring until it does
    /// (``scrollRidesFrames``), unless the CPU takes the camera first (``cpuTakesCamera()``).
    struct RenderClose {
        /// The camera's settle owed a leading-column report (``reportScrollOnSettle``): it goes at the landing.
        var reportsLeadingColumn = false
    }

    /// Now on this screen's layer clock, the one its render-server springs begin on.
    var renderClockTime: CFTimeInterval {
        let now = CACurrentMediaTime()
        return layer?.convertTime(now, from: nil) ?? now
    }

    /// A structural change lands while render-server springs still carry panes or dividers: each one's
    /// CPU frame takes what shows now, its position and its velocity (``RenderSpringTrack``), and those
    /// springs stop. The change then seeds its new panes and dividers from what shows, as on the CPU path,
    /// and whichever backend runs it goes on from that state (the render server restarts the springs from
    /// it: on a retarget the presented value and its velocity stay continuous). A close in flight gives up
    /// the camera until the render server takes this change too (``springCloseOnRenderServer()``).
    func takeRenderSpringsBack() {
        releaseRenderClose()
        zoomMotion.takeBackFromRenderServer()
        guard !renderTracks.isEmpty else { return }
        let now = renderClockTime
        for (pane, track) in renderTracks.panes {
            if let frame = paneFrames[pane] { paneFrames[pane] = track.presenting(frame, at: now) }
            context.hosts[pane]?.stopRenderMoves()
        }
        for (kind, track) in renderTracks.dividers {
            if let frame = dividerFrames[kind] { dividerFrames[kind] = track.presenting(frame, at: now) }
            dividerViews[kind]?.stopRenderMoves()
        }
        if renderTracks.strip { stopStripContainerSpring() }
        // Still arriving, as on the CPU path, until each frame really lands.
        arriving.formUnion(renderTracks.arriving)
        renderTracks = RenderTracks(tookBack: true)
    }

    /// Removes the position and size springs on `layer` (their components too); a fade keeps running.
    static func stopMoveSprings(_ layer: CALayer) {
        RenderSpring.stop(layer, "position")
        RenderSpring.stop(layer, "bounds.size")
    }

    /// The CPU takes the strip or a row column's camera (a wheel notch, a pan, a page, a center or reveal):
    /// the camera stops riding a close's frame spring, and a render-server close in flight gives up the
    /// camera, so its landing neither ends the CPU's motion nor reports: the report it owed goes with the
    /// CPU's settle.
    func cpuTakesCamera() {
        scrollRidesFrames = false
        releaseRenderClose()
    }

    /// A render-server close in flight no longer owns the camera (``cpuTakesCamera()``, or a structural
    /// change the render server may not take): the report it owed goes with the next settle.
    func releaseRenderClose() {
        guard let close = renderClose else { return }
        renderClose = nil
        if close.reportsLeadingColumn { reportScrollOnSettle = true }
    }

    /// The change's turn started a split (a pane growing in from its neighbour's edge, ``arriving``), or
    /// changed the structure while render-server springs still ran (their state came back to the CPU frames,
    /// ``takeRenderSpringsBack()``: the next split, the daemon's echo of the last one): its pane and divider
    /// springs go to the render server from what shows, at their velocities, and their CPU springs rest. A
    /// new dock column grows in the same way: its pane from its screen edge, and the
    /// strip's clip, the strip container's bounds, from the range beside the docks where they showed, at
    /// their speed (``springStripContainer(from:velocity:on:landed:)``). A close is
    /// ``springCloseOnRenderServer()``'s and a zoom ``springZoomOnRenderServer()``'s. A split whose turn also
    /// moves a camera on the CPU (the strip's reveal of the new pane, a row column's, a scroll area's or the
    /// canvas's) stays on the CPU step: each camera frame places every pane and divider at its shift.
    /// Returns whether it took the motion.
    func springSplitOnRenderServer() -> Bool { // perf-hot: 4ms motion-frame
        guard !arriving.isEmpty || renderTracks.tookBack, zoomMotion.pane == nil, !scrollRidesFrames, !isCameraMoving else { return false }
        // The strip's range beside the docks where they show now and its speed, before their springs rest:
        // plan apply only.
        let docks = growingDocks
        let stripFrom = docks.isEmpty ? nil : stripRange(in: geometry, beside: docks)
        let stripVelocity = PaneArrival.stripClipVelocity(geometry, docks: docks)
        // Where the views are laid out: a pan on the strip container shows them moved by its translation.
        let strip = geometry.viewShift(offset: layoutOffset), scale = self.scale
        let panes = SplitMotion.renderMoves(paneFrames.filter { entry in context.hosts[entry.key].map { holds($0) } ?? false }) { pane, rect in
            shownRect(rect, of: pane, strip: strip, scale: scale)
        }
        let dividers = SplitMotion.renderMoves(dividerFrames.filter { dividerViews[$0.key] != nil }) { kind, rect in
            shownRect(rect, of: kind, strip: strip, scale: scale)
        }
        guard !panes.isEmpty || !dividers.isEmpty else { return false }
        for pane in panes.keys { paneFrames[pane]?.snap() }
        for kind in dividers.keys { dividerFrames[kind]?.snap() }
        renderTracks.arriving.formUnion(arriving)
        springMoves(panes: panes, dividers: dividers, strip: stripFrom, stripVelocity: stripVelocity)
        return true
    }

    /// The change's turn closed panes (``scrollRidesFrames``: Cmd-W on either axis, the last column or row
    /// closed), or moved the camera while such a close is in flight (the focus the close lands, in its own
    /// turn). The strip camera and each row column's rest in the model now, and their shift rides the
    /// close's frame spring inside each pane's and divider's own spring, from where it shows to where it
    /// rests, at the velocity it shows with (the camera's included: Lawrence 2026-10-20, the close and its
    /// shift are one motion, on one curve). A zoom, a scroll area, a docked column (its strip clip is placed
    /// at rest until p03-rendering-023 makes it layer structure), the canvas camera and a pan in progress
    /// stay on the CPU step. Returns whether it took the motion; its landing reports the leading column the
    /// camera owed (``RenderClose``).
    func springCloseOnRenderServer() -> Bool { // perf-hot: 4ms motion-frame
        guard scrollRidesFrames, hasMotion, arriving.isEmpty, newDockColumns.isEmpty, zoomMotion.pane == nil, !isGesturing,
              !areasMoving, !canvasState.camera.isMoving, geometry.dock.isEmpty, baseGeometry.scrollAreas.isEmpty else { return false }
        let scale = self.scale
        let panes = paneFrames.filter { entry in context.hosts[entry.key].map { holds($0) } ?? false }
        let dividers = dividerFrames.filter { dividerViews[$0.key] != nil }
        // Where each shows now and how fast, at the cameras' presented offsets and velocities, before they rest.
        let strip = stripShift, stripVelocity = scroll.velocity
        let rowVelocities = rowScrolls.mapValues(\.state.spring.velocity)
        // A camera moving content at velocity v moves what it carries at -v in the view.
        func shown(_ frame: AnimatedFrame, at rect: CGRect, scrolls: Bool, row: ColumnID?) -> SplitMotion.Shown {
            let camera = RectComponents(x: scrolls ? -stripVelocity : 0, y: -(row.flatMap { rowVelocities[$0] } ?? 0))
            return SplitMotion.Shown(rect: rect, velocity: RectComponents(velocityOf: frame) + camera)
        }
        var shownPanes: [PaneID: SplitMotion.Shown] = [:], shownDividers: [DividerHandleView.Kind: SplitMotion.Shown] = [:]
        for (pane, frame) in panes {
            shownPanes[pane] = shown(frame, at: shownRect(frame.rect, of: pane, strip: strip, scale: scale),
                                     scrolls: geometry.scrolls(pane: pane), row: baseGeometry.rowColumnOfPane[pane])
        }
        for (kind, frame) in dividers {
            shownDividers[kind] = shown(frame, at: shownRect(frame.rect, of: kind, strip: strip, scale: scale),
                                        scrolls: scrolls(kind), row: rowColumn(of: kind))
        }
        if restCameras() { scrollbarFlash = true }
        let rest = stripShift
        let paneMoves = SplitMotion.renderMoves(panes, shown: shownPanes) { pane, rect in
            shownRect(rect, of: pane, strip: rest, scale: scale)
        }
        let dividerMoves = SplitMotion.renderMoves(dividers, shown: shownDividers) { kind, rect in
            shownRect(rect, of: kind, strip: rest, scale: scale)
        }
        // A pane whose own move the camera cancels (the column right of a closed one) shows still: it rests too.
        for pane in Array(paneFrames.keys) { paneFrames[pane]?.snap() }
        for kind in Array(dividerFrames.keys) { dividerFrames[kind]?.snap() }
        // The camera rests in the model: a report its settle owed goes out when the close lands, not on a CPU frame.
        renderClose = RenderClose(reportsLeadingColumn: renderClose?.reportsLeadingColumn == true || reportScrollOnSettle)
        reportScrollOnSettle = false
        springMoves(panes: paneMoves, dividers: dividerMoves)
        return true
    }

    /// The change's turn started a zoom or an unzoom (`PaneZoomMotion`), or changed the structure while one
    /// ran (its spring came back to the CPU frame, ``takeRenderSpringsBack()``): the zooming pane springs on
    /// the render server from where it shows, at its velocity, on the zoom token. Nothing else may move with
    /// it (another pane or divider, a camera, a pan, a dock column growing in): those changes stay on the CPU
    /// step. So does a zoom over or under a page in its own window (``PaneHostView/showsChildWindowContent``):
    /// that window follows the model frames, not the spring, until tasks 051 to 053 remove it. The panes the
    /// zoom covers and the stacking `reconcile` gave it are not touched until it lands
    /// (``renderSpringLanded()``). Returns whether it took the motion.
    func springZoomOnRenderServer() -> Bool { // perf-hot: 4ms motion-frame
        guard let pane = zoomMotion.pane, !zoomMotion.rendersOnServer, let frame = paneFrames[pane],
              let host = context.hosts[pane], holds(host), arriving.isEmpty, newDockColumns.isEmpty, !isGesturing,
              !scrollRidesFrames, !isCameraMoving,
              paneFrames.allSatisfy({ $0.key == pane || $0.value.showsRest }), dividerFrames.values.allSatisfy(\.showsRest),
              !displayedHosts.contains(where: \.showsChildWindowContent)
        else { return false }
        let strip = stripShift, scale = self.scale
        let moves = SplitMotion.renderMoves([pane: frame]) { pane, rect in shownRect(rect, of: pane, strip: strip, scale: scale) }
        guard let move = moves[pane] else { return false }
        paneFrames[pane]?.snap()
        zoomMotion.handToRenderServer(from: move.from, to: move.to)
        springMoves(panes: [pane: move], dividers: [:], token: zoomMotion.spring(for: pane))
        // The rings, dims and page cutouts behind it read its sweep now (``coverFrame(_:)``), not its rest frame.
        coverVersion &+= 1
        context.overlayNeedsSync()
        return true
    }

    /// Where `host` covers the panes stacked behind it (``shownFrame(_:)``). A zooming pane on the render
    /// server covers all it springs across until it lands: its model frame is at rest from the key's turn,
    /// so the panes it grows over lose their chrome at once and the panes it uncovers get theirs back at
    /// the landing, and no ring or dim on the overlay plane draws over it while it moves.
    func coverFrame(_ host: PaneHostView) -> CGRect {
        let shown = shownFrame(host)
        guard host.pane == zoomMotion.pane, let sweep = zoomMotion.renderSweep else { return shown }
        return shown.isNull ? sweep : shown.union(sweep)
    }

    /// A camera of this screen still moves: the strip's, a row column's, a scroll area's or the canvas's.
    private var isCameraMoving: Bool {
        (!isUserScrolling && (scroll.value != scroll.target || scroll.velocity != 0)) || rowsMoving || areasMoving
            || canvasState.camera.isMoving
    }

    /// The strip camera and each row column's rest at their targets, and hit testing reads the rest
    /// (``refreshRowShift()``). Returns whether the strip camera moved.
    private func restCameras() -> Bool {
        let moved = scroll.value != scroll.target || scroll.velocity != 0
        scroll.snap()
        for id in Array(rowScrolls.keys) { rowScrolls[id]?.state.spring.snap() }
        if !rowScrolls.isEmpty { refreshRowShift() }
        return moved
    }

    /// Springs `panes` (with their chrome, ``SplitMotion/placeAtRest(_:laysOut:context:placeDividers:)``) and `dividers`
    /// from where they show to their rest frames on the change's frame spring token (or `token`), and the strip container's
    /// range from `strip` (where it showed beside docks short of their rest, moving at `stripVelocity`) to its rest; records
    /// each spring (``renderTracks``); the layout motion ends when the last one lands (``renderSpringLanded()``).
    private func springMoves(panes: [PaneID: SplitMotion.RenderMove], dividers: [DividerHandleView.Kind: SplitMotion.RenderMove],
                             strip: CGRect? = nil, stripVelocity: RectComponents = .zero, token: MotionSpring? = nil) {
        let spring = Motion.panes.renderSpring(token ?? motionState.frameSpring)
        let laysOut = window != nil && bounds.width >= 1 && bounds.height >= 1
        let begin = renderClockTime, parameters = spring.parameters
        let landed: @MainActor @Sendable () -> Void = { [weak self] in self?.renderSpringLanded() }
        // The change holds one count of its own while it adds its springs, so a spring that lands at once
        // (its display draws no frames) cannot end the motion before the others start.
        renderSpringsInFlight += 1
        userMotionActive = true
        context.renderMotionBegan()
        context.userMotionStepped()
        // The clip first: the strip's hosts then spring inside the container at its rest range.
        renderSpringsInFlight += 1
        if springStripContainer(from: strip, velocity: stripVelocity, on: spring, landed: landed) { renderTracks.strip = true }
        // Each divider is a layer on the panes' spring: the one placement path puts it at
        // rest (frame, alpha, hidden state, clips), its one frame set before it lands.
        let placement = ScreenDividers(screen: self), uncovered = uncoveredRect, laidOutStrip = geometry.viewShift(offset: layoutOffset)
        let placed = SplitMotion.placeAtRest(panes, laysOut: laysOut, context: context) {
            for (kind, move) in dividers {
                guard let view = dividerViews[kind] else { continue }
                placement.place(view, kind, at: move.to, alpha: move.toAlpha, strip: laidOutStrip, uncovered: uncovered, force: true)
            }
        }
        for (pane, host, move) in placed {
            renderSpringsInFlight += 1
            let landedHost: @MainActor @Sendable () -> Void = { [weak self, weak host] in
                if let host { self?.hostLanded(host) }
                self?.renderSpringLanded()
            }
            host.springToRest(move, spring: spring, inPlane: context.overlayPlaneRect, landed: landedHost)
            renderTracks.panes[pane] = Self.tracking(renderTracks.panes[pane], move, animates: spring.animates("position", in: host),
                                                  begin: begin, parameters: parameters)
        }
        for (kind, move) in dividers {
            guard let view = dividerViews[kind] else { continue }
            renderSpringsInFlight += 1
            view.springToRest(move, spring: spring, landed: landed)
            renderTracks.dividers[kind] = Self.tracking(renderTracks.dividers[kind], move, animates: spring.animates("position", in: view),
                                                     begin: begin, parameters: parameters)
        }
        renderSpringLanded()
    }

    /// `track` with `move`'s spring added, or nil when the gate shows the move in one frame.
    private static func tracking(_ track: RenderSpringTrack?, _ move: SplitMotion.RenderMove, animates: Bool,
                                 begin: CFTimeInterval, parameters: SpringParameters) -> RenderSpringTrack? {
        guard animates else { return nil }
        var track = track ?? RenderSpringTrack()
        track.add(offset: RectComponents(move.from, minus: move.to), velocity: move.velocity, begin: begin, parameters: parameters)
        return track.isEmpty ? nil : track
    }

    /// A host's render-server spring call landed: it leaves its layout spring once no render-server spring
    /// carries it and no CPU spring moves its pane (a zoom or a dock column the CPU steps), whose own
    /// landing clears it then (``applyPresentation(force:)``).
    private func hostLanded(_ host: PaneHostView) {
        guard !host.isOnRenderSpring else { return }
        if let frame = paneFrames[host.pane], frame.rect != frame.targetRect { return }
        host.isOnLayoutSpring = false
    }

    /// One render-server spring call of this screen landed. After the last, divider hover follows the rest
    /// frames once, the visibility pass narrows to the rest (a pan held or not), and the layout motion ends,
    /// unless a pan holds it (``isGesturing``) or CPU springs still
    /// run (the root ends it when they land). A close still owning the camera (``RenderClose``) gives it back
    /// and sends the report it owed; a zoom gives its pane back its place in the stacking order and lets go
    /// of the panes it covered.
    func renderSpringLanded() {
        renderSpringsInFlight -= 1
        guard renderSpringsInFlight == 0 else { return }
        renderTracks = RenderTracks()
        if let close = renderClose {
            renderClose = nil
            scrollRidesFrames = false
            if close.reportsLeadingColumn { reportLeadingColumn() }
        }
        if zoomMotion.landedOnRenderServer() {
            // The covered panes go first, as on the CPU path (`step`): the pass below may end the layout motion,
            // and its observers and the interactive-rect report must not see them. Then `rank` without the
            // zooming pane, the strip container back at its range, the clips, covers and backing re-read once.
            releaseCovered()
            ensureStacking()
            applyPresentation(force: true)
            context.stripClipsDidChange()
        }
        // The dividers' clips follow the screen as it is now (a dock or a scroll area may have moved meanwhile).
        ScreenDividers(screen: self).place(strip: geometry.viewShift(offset: layoutOffset), scale: scale, uncovered: uncoveredRect,
                                           force: false)
        refreshDividerHover()
        context.renderSpringsLanded()
        context.overlayNeedsSync()
        guard userMotionActive, !isGesturing else { return }
        userMotionActive = false
        if !hasMotion { context.userMotionEnded() }
    }
}

extension SplitMotion {
    /// Where a pane or divider shows in the screen and how fast it moves there, in points per second.
    struct Shown {
        var rect: CGRect
        var velocity: RectComponents
    }

    /// The moves of `frames` from where each showed (`shown`, read before the change's cameras rested) to
    /// its rest rect placed by `rest`; a frame shown still at its rest is absent. Unlike a split's moves, a
    /// pane whose own frame does not change moves too when the camera that carries it does.
    static func renderMoves<Key: Hashable>(_ frames: [Key: AnimatedFrame], shown: [Key: Shown],
                                           rest: (Key, CGRect) -> CGRect) -> [Key: RenderMove] {
        var moves: [Key: RenderMove] = [:]
        for (key, frame) in frames {
            guard let from = shown[key] else { continue }
            let to = rest(key, frame.targetRect)
            guard from.rect != to || !from.velocity.isZero || frame.alpha.value != frame.alpha.target else { continue }
            moves[key] = RenderMove(from: from.rect, to: to, fromAlpha: frame.alpha.value, toAlpha: frame.alpha.target,
                                    velocity: from.velocity)
        }
        return moves
    }
}

private extension AnimatedFrame {
    /// The frame shows its rest: geometry and alpha at their targets (what ``ScreenContentView/hasMotion`` reads).
    var showsRest: Bool { rect == targetRect && alpha.value == alpha.target }
}

extension PaneHostView {
    /// A shown view in this pane draws in its own child window (`ChildWindowContent`). One walk of the
    /// pane's views, asked in a change's turn, never on a motion frame.
    var showsChildWindowContent: Bool { content.subtreeDrawsInChildWindow }
}
