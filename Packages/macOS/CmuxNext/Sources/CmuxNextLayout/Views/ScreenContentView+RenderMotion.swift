import AppKit
import CmuxNextDesign
import QuartzCore

/// A split or a close on the render server (chrome-parity R2, p03-rendering-022a and 022b; on with
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

extension ScreenContentView {
    /// The render-server springs still carrying this screen's panes and dividers (``RenderSpringTrack``),
    /// in the screen's coordinates.
    struct RenderTracks {
        var panes: [PaneID: RenderSpringTrack] = [:]
        var dividers: [DividerHandleView.Kind: RenderSpringTrack] = [:]
        /// This change turn took the springs back to the CPU frames (``takeRenderSpringsBack()``): the render
        /// server may take the motion again at the turn's end (``springSplitOnRenderServer()``).
        var tookBack = false

        var isEmpty: Bool { panes.isEmpty && dividers.isEmpty }
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
        guard !renderTracks.isEmpty else { return }
        let now = renderClockTime
        for (pane, track) in renderTracks.panes {
            if let frame = paneFrames[pane] { paneFrames[pane] = track.presenting(frame, at: now) }
            if let layer = context.hosts[pane]?.layer { Self.stopMoveSprings(layer) }
        }
        for (kind, track) in renderTracks.dividers {
            if let frame = dividerFrames[kind] { dividerFrames[kind] = track.presenting(frame, at: now) }
            if let layer = dividerViews[kind]?.layer { Self.stopMoveSprings(layer) }
        }
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
    /// close is ``springCloseOnRenderServer()``'s; a zoom (027), a new dock column (028) and a screen with a
    /// docked column (its strip clip is placed at rest until p03-rendering-023) stay on the CPU step.
    /// Returns whether it took the motion.
    func springSplitOnRenderServer() -> Bool { // perf-hot: 4ms motion-frame
        guard !arriving.isEmpty || renderTracks.tookBack, newDockColumns.isEmpty, geometry.dock.isEmpty, zoomMotion.pane == nil,
              !scrollRidesFrames else { return false }
        let strip = stripShift, scale = self.scale
        let panes = SplitMotion.renderMoves(paneFrames.filter { entry in context.hosts[entry.key].map { holds($0) } ?? false }) { pane, rect in
            shownRect(rect, of: pane, strip: strip, scale: scale)
        }
        let dividers = SplitMotion.renderMoves(dividerFrames.filter { dividerViews[$0.key] != nil }) { kind, rect in
            shownRect(rect, of: kind, strip: strip, scale: scale)
        }
        guard !panes.isEmpty || !dividers.isEmpty else { return false }
        for pane in panes.keys { paneFrames[pane]?.snap() }
        for kind in dividers.keys { dividerFrames[kind]?.snap() }
        springMoves(panes: panes, dividers: dividers)
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

    /// The strip camera and each row column's rest at their targets, and hit testing reads the rest
    /// (``refreshRowShift()``). Returns whether the strip camera moved.
    private func restCameras() -> Bool {
        let moved = scroll.value != scroll.target || scroll.velocity != 0
        scroll.snap()
        for id in Array(rowScrolls.keys) { rowScrolls[id]?.state.spring.snap() }
        if !rowScrolls.isEmpty { refreshRowShift() }
        return moved
    }

    /// Springs `panes` and `dividers` from where they show to their rest frames on the change's frame
    /// spring token, and records each spring (``renderTracks``); the layout motion ends when the last one
    /// lands (``renderSpringLanded()``).
    private func springMoves(panes: [PaneID: SplitMotion.RenderMove], dividers: [DividerHandleView.Kind: SplitMotion.RenderMove]) {
        let spring = Motion.panes.renderSpring(motionState.frameSpring)
        let laysOut = window != nil && bounds.width >= 1 && bounds.height >= 1
        let begin = renderClockTime, parameters = spring.parameters
        let landed: @MainActor @Sendable () -> Void = { [weak self] in self?.renderSpringLanded() }
        // The change holds one count of its own while it adds its springs, so a spring that lands at once
        // (its display draws no frames) cannot end the motion before the others start.
        renderSpringsInFlight += 1
        userMotionActive = true
        context.userMotionStepped()
        for (pane, move) in panes {
            guard let host = context.hosts[pane] else { continue }
            renderSpringsInFlight += 1
            let landedHost: @MainActor @Sendable () -> Void = { [weak self, weak host] in
                if let host { self?.hostLanded(host) }
                self?.renderSpringLanded()
            }
            host.springOnRenderServer(move, spring: spring, laysOut: laysOut && move.to.width >= 1 && move.to.height >= 1, landed: landedHost)
            renderTracks.panes[pane] = Self.tracking(renderTracks.panes[pane], move, animates: spring.animates("position", in: host),
                                                  begin: begin, parameters: parameters)
        }
        for (kind, move) in dividers {
            guard let view = dividerViews[kind] else { continue }
            renderSpringsInFlight += 1
            springDivider(view, move, on: spring, landed: landed)
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

    /// Moves a divider handle to its rest in this turn, its frame set once, and springs its layer there from
    /// where it showed (``NSView/renderSpringMoves(from:velocity:)``).
    private func springDivider(_ view: DividerHandleView, _ move: SplitMotion.RenderMove, on spring: RenderSpring,
                               landed: @escaping @MainActor @Sendable () -> Void) {
        view.frame = move.to
        view.alphaValue = move.toAlpha
        let moves = view.renderSpringMoves(from: move.from, velocity: move.velocity)
        guard !moves.isEmpty else { return landed() }
        spring.animateGroup(moves, in: view) { _ in landed() }
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
    /// frames once and the layout motion ends, unless a pan holds it (``isGesturing``) or CPU springs still
    /// run (the root ends it when they land). A close still owning the camera (``RenderClose``) gives it back
    /// and sends the report it owed.
    func renderSpringLanded() {
        renderSpringsInFlight -= 1
        guard renderSpringsInFlight == 0 else { return }
        renderTracks = RenderTracks()
        if let close = renderClose {
            renderClose = nil
            scrollRidesFrames = false
            if close.reportsLeadingColumn { reportLeadingColumn() }
        }
        refreshDividerHover()
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
