import AppKit
import CmuxNextDesign

/// A split on the render server (chrome-parity R2, p03-rendering-022a; on with `motion.renderServer`).
/// In the change's turn every pane and divider the split moves goes to its rest frame once, each resized
/// pane laid out once at its rest size after its content heard that size, and Core Animation shows each
/// one springing there from where it showed, on the split's spring token. The main thread does no work
/// per motion frame: Chromium's compositor owns its threaded animations the same way
/// (`cc/animation/animation_host.h`, `cc/animation/keyframe_model.h`), and Core Animation also animates
/// position and bounds on the render server (plans/cmux-next/chrome-parity/p03-rendering.md, section 1.3).
struct SplitRenderMotion: RenderServerMotion {
    var kind: RenderMotionKind { .splitClose }

    func begin(on screen: ScreenContentView, policy: MotionPolicy) -> MotionBackend {
        screen.springSplitOnRenderServer() ? .renderServer : .cpuStep
    }
}

extension ScreenContentView {
    /// The change's turn started a split (a pane growing in from its neighbour's edge, ``arriving``),
    /// possibly while the last split still springs: its pane and divider springs go to the render server,
    /// and their CPU springs rest. A close (task 022b), a zoom (027) and a new dock column (028) stay on
    /// the CPU step. Returns whether it took the motion.
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
        let spring = Motion.panes.renderSpring(motionState.frameSpring)
        let laysOut = window != nil && bounds.width >= 1 && bounds.height >= 1
        let landed: @MainActor @Sendable () -> Void = { [weak self] in self?.renderSpringLanded() }
        // The split holds one count of its own while it adds its springs, so a spring that lands at once
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
        return true
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
        refreshDividerHover()
        guard userMotionActive, !isGesturing else { return }
        userMotionActive = false
        if !hasMotion { context.userMotionEnded() }
    }
}
