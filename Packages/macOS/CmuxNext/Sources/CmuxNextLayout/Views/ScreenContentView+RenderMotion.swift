import AppKit
import CmuxNextDesign

/// A split or a close on the render server (chrome-parity R2, p03-rendering-022a and 022b; on with
/// `motion.renderServer`). In the change's turn every pane and divider the change moves goes to its rest
/// frame once, each resized pane laid out once at its rest size after its content heard that size, and
/// Core Animation shows each one springing there from where it showed, on the change's spring token. The
/// main thread does no work per motion frame: Chromium's compositor owns its threaded animations the same
/// way (`cc/animation/animation_host.h`, `cc/animation/keyframe_model.h`), and Core Animation also animates
/// position and bounds on the render server (plans/cmux-next/chrome-parity/p03-rendering.md, section 1.3).
struct SplitRenderMotion: RenderServerMotion {
    var kind: RenderMotionKind { .splitClose }

    func begin(on screen: ScreenContentView, policy: MotionPolicy) -> MotionBackend {
        screen.springSplitOnRenderServer() || screen.springCloseOnRenderServer() ? .renderServer : .cpuStep
    }
}

extension ScreenContentView {
    /// The change's turn started a split (a pane growing in from its neighbour's edge, ``arriving``),
    /// possibly while the last split still springs: its pane and divider springs go to the render server,
    /// and their CPU springs rest. A close is ``springCloseOnRenderServer()``'s; a zoom (027) and a new dock
    /// column (028) stay on the CPU step. Returns whether it took the motion.
    func springSplitOnRenderServer() -> Bool { // perf-hot: 4ms motion-frame
        guard !arriving.isEmpty, newDockColumns.isEmpty, zoomMotion.pane == nil, !scrollRidesFrames else { return false }
        let strip = stripShift, scale = self.scale
        let panes = SplitMotion.renderMoves(paneFrames.filter { context.hosts[$0.key]?.superview === self }) { pane, rect in
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
    /// rests (Lawrence 2026-10-20: the close and its shift are one motion, on one curve). A zoom, a scroll
    /// area's camera, the canvas camera and a pan in progress stay on the CPU step. Returns whether it took
    /// the motion; its landing reports the leading column the camera owed (``RenderClose``).
    func springCloseOnRenderServer() -> Bool { // perf-hot: 4ms motion-frame
        guard scrollRidesFrames, hasMotion, arriving.isEmpty, newDockColumns.isEmpty, zoomMotion.pane == nil, !isGesturing,
              !areasMoving, !canvasState.camera.isMoving else { return false }
        let scale = self.scale
        let panes = paneFrames.filter { context.hosts[$0.key]?.superview === self }
        let dividers = dividerFrames.filter { dividerViews[$0.key] != nil }
        // Where each shows now, at the cameras' presented offsets, before they rest.
        let strip = stripShift
        let shownPanes = Dictionary(uniqueKeysWithValues: panes.map { pane, frame in
            (pane, shownRect(frame.rect, of: pane, strip: strip, scale: scale))
        })
        let shownDividers = Dictionary(uniqueKeysWithValues: dividers.map { kind, frame in
            (kind, shownRect(frame.rect, of: kind, strip: strip, scale: scale))
        })
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

    /// A close on the render server that has not landed: the camera rides its frame spring until it does
    /// (``scrollRidesFrames``).
    struct RenderClose {
        /// The camera's settle owed a leading-column report (``reportScrollOnSettle``): it goes at the landing.
        var reportsLeadingColumn = false
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
    /// spring token; the layout motion ends when the last one lands (``renderSpringLanded()``).
    private func springMoves(panes: [PaneID: SplitMotion.RenderMove], dividers: [DividerHandleView.Kind: SplitMotion.RenderMove]) {
        let spring = Motion.panes.renderSpring(motionState.frameSpring)
        let laysOut = window != nil && bounds.width >= 1 && bounds.height >= 1
        let landed: @MainActor @Sendable () -> Void = { [weak self] in self?.renderSpringLanded() }
        // The change holds one count of its own while it adds its springs, so a spring that lands at once
        // (its display draws no frames) cannot end the motion before the others start.
        renderSpringsInFlight += 1
        userMotionActive = true
        context.userMotionStepped()
        for (pane, move) in panes {
            guard let host = context.hosts[pane] else { continue }
            renderSpringsInFlight += 1
            host.springOnRenderServer(from: move.from, alpha: move.fromAlpha, to: move.to, alpha: move.toAlpha, spring: spring,
                                      laysOut: laysOut && move.to.width >= 1 && move.to.height >= 1, landed: landed)
        }
        for (kind, move) in dividers {
            guard let view = dividerViews[kind] else { continue }
            renderSpringsInFlight += 1
            springDivider(view, move, on: spring, landed: landed)
        }
        renderSpringLanded()
    }

    /// Moves a divider handle to its rest in this turn and springs its layer there from where it showed.
    private func springDivider(_ view: DividerHandleView, _ move: SplitMotion.RenderMove, on spring: RenderSpring,
                               landed: @escaping @MainActor @Sendable () -> Void) {
        // AppKit maps the frame to the layer: the spring starts from the layer geometry it writes for `from`.
        view.frame = move.from
        let start = (position: view.layer?.position ?? .zero, size: view.layer?.bounds.size ?? .zero)
        view.frame = move.to
        view.alphaValue = move.toAlpha
        guard let layer = view.layer else { return landed() }
        spring.animateGroup([RenderSpring.Move(layer, "position", from: start.position, to: layer.position),
                             RenderSpring.Move(layer, "bounds.size", from: start.size, to: layer.bounds.size)],
                            in: view) { _ in landed() }
    }

    /// One render-server spring call of this screen landed. After the last, divider hover follows the rest
    /// frames once and the layout motion ends, unless a pan holds it (``isGesturing``) or CPU springs still
    /// run (the root ends it when they land).
    func renderSpringLanded() {
        renderSpringsInFlight -= 1
        guard renderSpringsInFlight == 0 else { return }
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
    /// The moves of `frames` from where each showed (`shown`, read before the change's cameras rested) to
    /// its rest rect placed by `rest`; a frame shown at its rest is absent. Unlike a split's moves, a pane
    /// whose own frame does not change moves too when the camera that carries it does.
    static func renderMoves<Key: Hashable>(_ frames: [Key: AnimatedFrame], shown: [Key: CGRect],
                                           rest: (Key, CGRect) -> CGRect) -> [Key: RenderMove] {
        var moves: [Key: RenderMove] = [:]
        for (key, frame) in frames {
            guard let from = shown[key] else { continue }
            let to = rest(key, frame.targetRect)
            guard from != to || frame.alpha.value != frame.alpha.target else { continue }
            moves[key] = RenderMove(from: from, to: to, fromAlpha: frame.alpha.value, toAlpha: frame.alpha.target)
        }
        return moves
    }
}
