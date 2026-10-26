import AppKit
import CmuxNextDesign
import QuartzCore

/// A split on the render server (chrome-parity R2, p03-rendering-022a; on with `motion.renderServer`).
/// In the change's turn every pane and divider the split moves goes to its rest frame once, each resized
/// pane laid out once at its rest size after its content heard that size, and Core Animation shows each
/// one springing there from where it showed, with its velocity, on the split's spring token from one begin
/// time; each pane's chrome in the overlay plane springs with it (``PaneChromeSpring``). The main thread does
/// no work per motion frame: Chromium's compositor owns its threaded animations the same way
/// (`cc/animation/animation_host.h`, `cc/animation/keyframe_model.h`), and Core Animation also animates
/// position and bounds on the render server (plans/cmux-next/chrome-parity/p03-rendering.md, section 1.3).
///
/// The screen's frames stay the one model of the motion: each change turn opens with the frames the render
/// server carries showing what it shows (``RenderTrack``), so the reconcile pass starts a split from there as
/// it does on the CPU (a new pane and divider ride the moving edge they open from, `SplitMotion.ride` and
/// `startShift`), and a turn the variant does not take gives those frames back to the CPU step, velocity and all.
struct SplitRenderMotion: RenderServerMotion {
    var kind: RenderMotionKind { .splitClose }

    func begin(on screen: ScreenContentView, policy: MotionPolicy) -> MotionBackend {
        screen.springSplitOnRenderServer() ? .renderServer : .cpuStep
    }
}

extension ScreenContentView {
    /// Render-server spring calls of this screen's panes and dividers that have not landed.
    var renderSpringsInFlight: Int { renderMotion.inFlight }

    // MARK: Change turns

    /// A change turn opens (``beginMotionTurn()``): each frame the render server carries takes what it shows
    /// now and its velocity. With the render server switched off since those springs started (`live` false),
    /// the CPU step takes them over now.
    func openRenderTurn(live: Bool) {
        renderMotion.cpuMovedAtTurnStart = live
            && (paneFrames.contains { renderMotion.tracks[.pane($0.key)] == nil && $0.value.isOffRest }
                || dividerFrames.contains { renderMotion.tracks[.divider($0.key)] == nil && $0.value.isOffRest })
        guard !renderMotion.tracks.isEmpty else { return }
        let now = CACurrentMediaTime()
        for (item, track) in renderMotion.tracks {
            switch item {
            case .pane(let pane):
                guard var frame = paneFrames[pane], let layer = context.hosts[pane]?.layer else { continue }
                track.adopt(into: &frame, at: layer.convertTime(now, from: nil))
                paneFrames[pane] = frame
            case .divider(let kind):
                guard var frame = dividerFrames[kind], let layer = dividerViews[kind]?.layer else { continue }
                track.adopt(into: &frame, at: layer.convertTime(now, from: nil))
                dividerFrames[kind] = frame
            }
        }
        guard live else {
            handRenderSpringsToCPU()
            renderMotion.handedBack = true
            applyPresentation()
            return
        }
        renderMotion.adopted = true
    }

    /// A change turn closes (``endMotionTurn(needsFrames:policy:)``), after its render-server kinds took their
    /// motions (`taken`: the split did, and placed every tracked frame). Otherwise the tracked frames go back
    /// to their rest under the springs still running, or, when the change gave one a new rest, all of them
    /// go to the CPU step from where they show.
    func closeRenderTurn(taken: Bool) -> RenderTurnEnd {
        defer { (renderMotion.adopted, renderMotion.handedBack) = (false, false) }
        if renderMotion.handedBack { return .handedBack }
        if taken { return .carried }
        guard renderMotion.adopted else { return .untouched }
        landDepartedRenderSprings()
        if renderMotion.tracks.contains(where: { restRect(of: $0.key) != $0.value.rest }) {
            handRenderSpringsToCPU()
            return .handedBack
        }
        for item in renderMotion.tracks.keys { snapFrame(of: item) }
        return .carried
    }

    // MARK: The split

    /// The change's turn started a split (a pane growing in from its neighbour's edge, ``arriving``),
    /// possibly while the last split still springs on the render server: it goes there too. A close (task
    /// 022b), a zoom (027), a new dock column (028), and a split landing while frames still move on the CPU
    /// stay on the CPU step. Returns whether it took the motion.
    func springSplitOnRenderServer() -> Bool {
        guard !arriving.isEmpty, newDockColumns.isEmpty, zoomMotion.pane == nil, !scrollRidesFrames,
              !renderMotion.cpuMovedAtTurnStart else { return false }
        applySplitOnRenderServer()
        return true
    }

    /// Every pane and divider off its rest, or given a new one, goes there on the render server; every frame
    /// rests in the CPU model.
    private func applySplitOnRenderServer() { // perf-hot: 4ms motion-frame
        landDepartedRenderSprings()
        let strip = stripShift, scale = self.scale
        let spring = Motion.panes.renderSpring(motionState.frameSpring), begin = CACurrentMediaTime()
        let laysOut = window != nil && bounds.width >= 1 && bounds.height >= 1
        // The split holds one count of its own while it adds its springs, so a spring that lands at once
        // (its display draws no frames) cannot end the motion before the others start.
        renderMotion.inFlight += 1
        userMotionActive = true
        context.userMotionStepped()
        for pane in Array(paneFrames.keys) {
            guard let host = context.hosts[pane], host.superview === self, var frame = paneFrames[pane] else { continue }
            let move = renderMove(.pane(pane), frame, model: host.frame) { shownRect($0, of: pane, strip: strip, scale: scale) }
            frame.snap()
            paneFrames[pane] = frame
            guard let move else { continue }
            let call = RenderSpringCall { [weak self, weak host] settles in
                host?.renderSpringLanded(settles: settles)
                self?.renderCallLanded(.pane(pane))
            }
            recordTrack(.pane(pane), rest: frame.targetRect, move: move, spring: spring, begin: begin, layer: host.layer, call: call)
            host.springOnRenderServer(move, restSize: frame.targetRect.size, spring: spring, begin: begin,
                                      laysOut: laysOut && move.to.width >= 1 && move.to.height >= 1, call: call)
        }
        for kind in Array(dividerFrames.keys) {
            guard let view = dividerViews[kind], var frame = dividerFrames[kind] else { continue }
            let move = renderMove(.divider(kind), frame, model: view.frame) { shownRect($0, of: kind, strip: strip, scale: scale) }
            frame.snap()
            dividerFrames[kind] = frame
            guard let move else { continue }
            let call = RenderSpringCall { [weak self] _ in self?.renderCallLanded(.divider(kind)) }
            recordTrack(.divider(kind), rest: frame.targetRect, move: move, spring: spring, begin: begin, layer: view.layer, call: call)
            springDivider(view, move, spring: spring, begin: begin, call: call)
        }
        renderSpringLanded()
    }

    /// The move of one frame, each rect placed in the screen by `place`; nil when it has nothing to move.
    /// A frame the render server carries keeps its running springs, which carry what shows and its velocity:
    /// a new rest adds one spring from its view's frame (`model`, the layer's model value: the old rest where
    /// the last presentation placed it, `RenderSpring`). Any other frame springs from what it shows with its
    /// velocity (a new pane's sliver riding a moving edge has that edge's).
    private func renderMove(_ item: ScreenRenderMotion.Item, _ frame: AnimatedFrame, model: CGRect,
                            place: (CGRect) -> CGRect) -> RenderMove? {
        let to = place(frame.targetRect)
        if let track = renderMotion.tracks[item] {
            guard track.rest != frame.targetRect else { return nil }
            return RenderMove(to: to, offset: FrameDelta(from: model, to: to), velocity: .zero,
                              fromAlpha: frame.alpha.target, toAlpha: frame.alpha.target)
        }
        guard frame.isOffRest else { return nil }
        return RenderMove(to: to, offset: FrameDelta(from: place(frame.rect), to: to), velocity: FrameDelta(velocityOf: frame),
                          fromAlpha: frame.alpha.value, toAlpha: frame.alpha.target)
    }

    /// Records `call`'s spring on `item`'s track before it starts (a spring that cannot animate lands in the call).
    private func recordTrack(_ item: ScreenRenderMotion.Item, rest: CGRect, move: RenderMove, spring: RenderSpring,
                       begin: CFTimeInterval, layer: CALayer?, call: RenderSpringCall) {
        var track = renderMotion.tracks[item] ?? RenderTrack(rest: rest)
        track.rest = rest
        if let layer {
            track.parts.append(RenderTrack.Part(offset: move.offset, velocity: move.velocity,
                                                begin: layer.convertTime(begin, from: nil), spring: spring.parameters))
        }
        track.calls.append(call)
        renderMotion.tracks[item] = track
        renderMotion.inFlight += 1
    }

    /// Moves a divider handle to its rest in this turn and springs its layer there from where it showed.
    private func springDivider(_ view: DividerHandleView, _ move: RenderMove, spring: RenderSpring, begin: CFTimeInterval,
                               call: RenderSpringCall) {
        if view.frame != move.to { view.frame = move.to }
        if view.alphaValue != move.toAlpha { view.alphaValue = move.toAlpha }
        guard let layer = view.layer else { return call.land() }
        let moves = layer.springMoves(offset: move.offset, velocity: move.velocity, flipsY: layerFlipsY)
        spring.animateGroup(moves, in: view, startingAt: begin) { _ in call.land() }
    }

    // MARK: Landing

    /// One spring call of `item` landed: its track goes once its last call did.
    private func renderCallLanded(_ item: ScreenRenderMotion.Item) {
        if var track = renderMotion.tracks[item] {
            track.calls.removeAll { !$0.isPending }
            renderMotion.tracks[item] = track.calls.isEmpty ? nil : track
        }
        renderSpringLanded()
    }

    /// One render-server spring call of this screen landed. After the last, divider hover follows the rest
    /// frames once and the layout motion ends, unless a pan holds it (``isGesturing``) or CPU springs still
    /// run (the root ends it when they land).
    private func renderSpringLanded() {
        renderMotion.inFlight -= 1
        guard renderMotion.inFlight == 0 else { return }
        refreshDividerHover()
        guard userMotionActive, !isGesturing else { return }
        userMotionActive = false
        if !hasMotion { context.userMotionEnded() }
    }

    /// Lands the calls of the panes and dividers that left this screen: a layer out of the tree may never end
    /// its springs, and the layout motion waits for every call.
    func landDepartedRenderSprings() {
        let departed = renderMotion.tracks.filter { !holds($0.key) }
        for call in departed.values.flatMap(\.calls) { call.land() }
    }

    /// Ends every render-server spring of this screen now: each item shows its model frame, and every call
    /// lands. `settles` false: the CPU step moves the items on from where their frames show.
    func stopRenderSprings(settles: Bool) {
        let tracks = renderMotion.tracks
        guard !tracks.isEmpty else { return }
        for item in tracks.keys {
            switch item {
            case .pane(let pane): context.hosts[pane]?.stopRenderSprings()
            case .divider(let kind): dividerViews[kind]?.stopRenderSprings()
            }
        }
        for call in tracks.values.flatMap(\.calls) { call.land(settles: settles) }
    }

    /// The CPU step takes the motion of every tracked frame (they show what the render server showed).
    private func handRenderSpringsToCPU() {
        stopRenderSprings(settles: false)
        context.requestFrames()
    }

    private func holds(_ item: ScreenRenderMotion.Item) -> Bool {
        switch item {
        case .pane(let pane): paneFrames[pane] != nil && context.hosts[pane]?.superview === self
        case .divider(let kind): dividerFrames[kind] != nil && dividerViews[kind] != nil
        }
    }

    private func restRect(of item: ScreenRenderMotion.Item) -> CGRect? {
        switch item {
        case .pane(let pane): paneFrames[pane]?.targetRect
        case .divider(let kind): dividerFrames[kind]?.targetRect
        }
    }

    private func snapFrame(of item: ScreenRenderMotion.Item) {
        switch item {
        case .pane(let pane): paneFrames[pane]?.snap()
        case .divider(let kind): dividerFrames[kind]?.snap()
        }
    }
}
