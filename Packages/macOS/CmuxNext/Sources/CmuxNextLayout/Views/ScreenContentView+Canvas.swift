import AppKit
import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups
import QuartzCore

/// A screen shown as a canvas (plans/cmux-next/canvas-layout.md). The camera is
/// the view's bounds: AppKit scales drawing, hit testing and every
/// `convert(_:from:)` for it, so hosts, rings, drops and page windows follow it
/// with no camera math of their own. The empty canvas pans with a drag; the
/// band around each pane moves (above it) or resizes (sides and corners) it.
/// With `motion.renderServer` on, an animated camera move rests the bounds at
/// its target in the change's turn and Core Animation shows the move there
/// (``CanvasRenderMotion``).
extension ScreenContentView {
    /// The screen shows a canvas now (not while a pane is zoomed over it).
    var isCanvas: Bool { canvasState.canvas != nil }

    /// Takes the model's canvas for this screen (nil: the daemon layout). A
    /// newer model camera is the target the shown camera moves to. Returns
    /// false when the screen went into or out of canvas mode: its frames
    /// change coordinate space, so they snap.
    func updateCanvas(_ canvas: CanvasScreen?, animated: Bool) -> Bool {
        let entering = canvas != nil && canvasState.canvas == nil
        let modeChanged = entering || (canvas == nil && canvasState.canvas != nil)
        canvasState.canvas = canvas
        guard let canvas else {
            stopCanvasCameraOnRenderServer()
            canvasState.modelCamera = nil
            canvasState.drag = nil
            endCanvasDragFrames()
            if modeChanged { window?.invalidateCursorRects(for: self) }
            return !modeChanged
        }
        if canvas.camera != canvasState.modelCamera {
            canvasState.modelCamera = canvas.camera
            // A window not on screen (or Reduce Motion) shows the new camera at once.
            let animates = animated && !entering && !context.reduceMotion && window?.isVisible == true
            // The main thread moves the camera on from what shows, unless the render server takes the move
            // at the end of the turn (``springCanvasCameraOnRenderServer()``).
            if !animates || !motionBackends.isLive { takeCanvasCameraBack() }
            canvasState.camera.retarget(canvas.camera, animated: animates)
        }
        window?.invalidateCursorRects(for: self)
        return !modeChanged
    }

    /// Pane frames of a canvas screen, in the canvas points the bounds show.
    var canvasGeometry: ScreenGeometry? {
        canvasState.canvas.map { ScreenGeometry.canvas($0, visible: bounds) }
    }

    /// Sets the bounds to the camera shown now (identity without a canvas)
    /// and reports the viewport to the model.
    func applyCamera() {
        applyBounds(showing: canvasState.canvas != nil ? canvasState.camera.shown : nil)
    }

    /// Sets the bounds to what `camera` shows (identity for nil) and reports the viewport to the model.
    private func applyBounds(showing camera: CanvasCamera?) {
        let size = frame.size
        guard size.width > 0, size.height > 0 else { return }
        let target = camera?.visibleRect(viewport: size) ?? CGRect(origin: .zero, size: size)
        guard bounds != target else { return }
        // AppKit reports a bounds size change as a backing change: it must not reconcile (Crash D).
        isApplyingCamera = true
        defer { isApplyingCamera = false }
        if bounds.size != target.size { setBoundsSize(target.size) }
        if bounds.origin != target.origin { setBoundsOrigin(target.origin) }
        if canvasState.canvas != nil { context.model.reportCanvasViewport(size, for: screenID) }
        context.overlayNeedsSync()
    }

    /// Advances the camera toward its target on the main thread (``step(_:policy:)``, when the render
    /// server does not run the move); true while it moves.
    func stepCanvasCamera(_ dt: Double, policy: MotionPolicy) -> Bool {
        guard isCanvas, canvasState.camera.isMoving else { return false }
        let moving = canvasState.camera.advance(dt, parameters: policy.spring(.scroll))
        applyCamera()
        return moving
    }

    // MARK: Render server

    /// The change's turn moved the camera toward a new target (an action's zoom, reveal or overview) and
    /// the main thread would step it there: the bounds rest at the target now, laid out once, and Core
    /// Animation shows the move from what showed, at its speed, on the screen layer
    /// (``CanvasCameraRenderSpring``): no main-thread work per motion frame. A page drawn in its own window
    /// follows the bounds, not the layer, so a screen showing one stays on the main thread's step, as does
    /// a layer whose `sublayerTransform` is not the identity at rest. Returns whether it took the move.
    func springCanvasCameraOnRenderServer() -> Bool {
        guard isCanvas, canvasState.camera.isMoving else { return false }
        let size = frame.size
        guard let layer, window != nil, size.width > 0, size.height > 0, canvasState.drag == nil,
              !displayedHosts.contains(where: \.showsChildWindowContent) else {
            takeCanvasCameraBack()
            return false
        }
        let now = renderClockTime
        applyBounds(showing: canvasState.camera.target)
        let axes = RenderLayerAxes(self)
        guard CATransform3DIsIdentity(layer.sublayerTransform), axes.x != 0, axes.y != 0 else {
            applyCamera()
            takeCanvasCameraBack()
            return false
        }
        let spring = Motion.panes.renderSpring(.scroll)
        let added = canvasState.camera.handToRenderServer(at: now, axes: axes, parameters: spring.parameters)
        // The zoom pivots on the viewport center at this size; a resize takes the move back first
        // (`reconcileAndScroll`), so no running spring keeps an older center.
        let rest = layer.bounds, anchor = layer.anchorPoint
        let pivot = CGPoint(x: (0.5 - anchor.x) * rest.width, y: (0.5 - anchor.y) * rest.height)
        let reach = hypot(rest.width, rest.height) / 2
        // Every call names all three key paths, so the newest call's landing waits for every camera spring.
        var moves = [
            RenderSpring.Move(layer, .boundsOriginX, from: rest.origin.x + added.centerOffset.x, to: rest.origin.x,
                              velocity: added.centerVelocity.x),
            RenderSpring.Move(layer, .boundsOriginY, from: rest.origin.y + added.centerOffset.y, to: rest.origin.y,
                              velocity: added.centerVelocity.y),
        ]
        // Each zoom spring carries its share of the zoom's speed as a progress velocity (`CanvasCameraRenderSpring.Zoom`);
        // with none, a still one names the key path.
        let zooms: [(ratio: Double, progress: Double)] = added.zooms.map { ($0.ratio, -$0.velocity) }
        for zoom in zooms.isEmpty ? [(ratio: 1.0, progress: 0.0)] : zooms {
            let from = CanvasZoomTransform(scale: CGFloat(zoom.ratio), pivot: pivot, reach: reach)
            moves.append(RenderSpring.Move(layer, .canvasZoom, from: from, to: .springZero, progressVelocity: CGFloat(zoom.progress)))
        }
        renderSpringsInFlight += 1
        userMotionActive = true
        context.userMotionStepped()
        spring.animateGroup(moves, in: self) { [weak self] finished in
            guard let self else { return }
            if finished { canvasState.camera.renderServerStopped() }
            renderSpringLanded()
        }
        return true
    }

    /// The main thread takes a render-server camera move back: its springs go on from what shows now, at
    /// that speed, and the bounds show it in this turn. Nothing happens while the render server runs none.
    func takeCanvasCameraBack() {
        guard canvasState.camera.takeBackFromRenderServer(at: renderClockTime) else { return }
        stopCanvasCameraSprings()
        applyCamera()
        if canvasState.camera.isMoving { context.requestFrames() }
    }

    /// The screen leaves canvas mode: the camera's render-server springs stop where they are.
    func stopCanvasCameraOnRenderServer() {
        guard canvasState.camera.onRenderServer != nil else { return }
        canvasState.camera.renderServerStopped()
        stopCanvasCameraSprings()
    }

    private func stopCanvasCameraSprings() {
        guard let layer else { return }
        RenderSpring.stop(layer, "bounds.origin")
        RenderSpring.stop(layer, "sublayerTransform")
    }

    /// Hosts stacked in the canvas's order, back to front; other views keep theirs.
    func reconcileCanvasStacking() {
        guard let order = canvasState.canvas?.order else { return }
        let index = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ranks = subviews.enumerated().map { position, view in
            ((view as? PaneHostView).flatMap { index[$0.pane] } ?? order.count) * 100_000 + position
        }
        guard ranks != ranks.sorted() else { return }
        StackingTable(ranks: Dictionary(zip(subviews.map(ObjectIdentifier.init), ranks), uniquingKeysWith: { first, _ in first })).sort(self)
    }

    // MARK: Trackpad

    /// Pans the camera with the pointer (`delta` screen points, natural direction). Live; `ended` reports it.
    func canvasPan(by delta: CGSize, ended: Bool) {
        guard isCanvas else { return }
        takeCanvasCameraBack()
        if delta != .zero {
            canvasState.camera.retarget(canvasState.camera.shown.panned(byScreenDelta: delta), animated: false)
            applyCamera()
        }
        if ended { reportCamera() }
    }

    /// Zooms by `factor` about `windowPoint` (a pinch). Live; `ended` reports it.
    func canvasMagnify(by factor: CGFloat, at windowPoint: NSPoint, ended: Bool) {
        guard isCanvas else { return }
        takeCanvasCameraBack()
        let anchor = convert(windowPoint, from: nil)
        canvasState.camera.retarget(canvasState.camera.shown.zoomed(by: factor, around: anchor), animated: false)
        applyCamera()
        window?.invalidateCursorRects(for: self)
        if ended { reportCamera() }
    }

    /// The model takes the camera the pointer left: a later action starts there.
    private func reportCamera() {
        let camera = canvasState.camera.target
        canvasState.modelCamera = camera
        context.model.setCanvasCamera(camera, for: screenID)
    }

    // MARK: Pointer

    /// A drag on the empty canvas pans it; it never moves the window.
    override var mouseDownCanMoveWindow: Bool { !isCanvas && super.mouseDownCanMoveWindow }

    private var canvasHandles: CanvasHandles? {
        canvasState.canvas.map { CanvasHandles(canvas: $0, thickness: ScreenCanvasState.handleThickness / canvasState.camera.shown.zoom) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let canvas = canvasState.canvas else { return super.mouseDown(with: event) }
        // The pointer hits what shows: the main thread takes a render-server move back first.
        takeCanvasCameraBack()
        let point = convert(event.locationInWindow, from: nil)
        if let hit = canvasHandles?.hit(point), let frame = canvas.frames[hit.pane] {
            canvasState.drag = .pane(CanvasPaneDrag(pane: hit.pane, start: frame, edges: hit.edges, minimumSize: context.style.minimumPaneSize),
                                     origin: event.locationInWindow)
            context.model.setGestureActive(true)
            context.model.focus(hit.pane, source: .pointer)
            context.model.setCanvasFrame(frame, for: hit.pane, raise: true)
        } else {
            canvasState.drag = .pan(origin: event.locationInWindow, from: canvasState.camera.shown)
        }
        beginCanvasDragFrames()
    }

    // local-monitor-allow: the drag goes to the window's FrameInputCoalescer (dragFrames), one move per frame to the latest point; only a view with no coalescer (tests, feature off) moves per event
    override func mouseDragged(with event: NSEvent) { // perf-hot: 2ms resize-drag (every canvas drag event)
        guard canvasState.drag != nil else { return super.mouseDragged(with: event) }
        if let frames = canvasState.dragFrames, frames.post(event) { return }
        moveCanvasDrag(to: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard canvasState.drag != nil else { return super.mouseUp(with: event) }
        // The frame's pending move lands before the release (Chromium's ShouldFlushQueue); the delivery
        // writes `canvasState`, so the consumer is read out of it first.
        let frames = canvasState.dragFrames
        frames?.flush()
        endCanvasDragFrames()
        guard let drag = canvasState.drag else { return }
        canvasState.drag = nil
        switch drag {
        case .pane:
            context.model.setGestureActive(false)
        case .pan:
            reportCamera()
        }
        window?.invalidateCursorRects(for: self)
    }

    /// The drag's moves on its window's coalescer (feature `pointerFrameDrags`, ``LayoutRootView/dragFrameInput``):
    /// a frame interval's first drag event moves the pane or the camera in its own turn, the rest once at the
    /// frame to the latest point, as Chromium delivers rAF-aligned moves
    /// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`). Without the
    /// coalescers every drag event moves it at once.
    private func beginCanvasDragFrames() {
        endCanvasDragFrames()
        guard let window, let frames = context.dragFrameInput else { return }
        canvasState.dragFrames = frames.coalescer(for: window).consumer(owner: "ScreenContentView.canvasDrag") { [weak self] input in
            self?.moveCanvasDrag(to: CGPoint(x: input.latest.location.x, y: input.latest.location.y))
        }
    }

    /// Drops the drag's consumer and the moves it still holds.
    private func endCanvasDragFrames() {
        let frames = canvasState.dragFrames
        canvasState.dragFrames = nil
        frames?.cancel()
    }

    /// Moves the dragged pane, or pans the camera, to the pointer at `windowPoint` (one delivery).
    private func moveCanvasDrag(to windowPoint: CGPoint) { // perf-hot: 2ms resize-drag (each canvas drag delivery)
        guard let drag = canvasState.drag else { return }
        switch drag {
        case let .pane(pane, origin):
            let zoom = canvasState.camera.shown.zoom
            // Window points grow up; canvas points grow down.
            let translation = CGSize(width: (windowPoint.x - origin.x) / zoom, height: (origin.y - windowPoint.y) / zoom)
            context.model.setCanvasFrame(pane.frame(translation: translation), for: pane.pane)
        case let .pan(origin, from):
            let delta = CGSize(width: windowPoint.x - origin.x, height: origin.y - windowPoint.y)
            canvasState.camera.retarget(from.panned(byScreenDelta: delta), animated: false)
            applyCamera()
        }
        context.requestFrames()
    }

    // cursor-rects-allow: canvas screens only: per-pane edge and corner bands, five cursors in one view (a strip screen adds none)
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let canvas = canvasState.canvas else { return }
        let band = ScreenCanvasState.handleThickness / canvasState.camera.shown.zoom
        for pane in canvas.order {
            guard let frame = canvas.frames[pane] else { continue }
            addCursorRect(CGRect(x: frame.minX, y: frame.minY - band, width: frame.width, height: band), cursor: .openHand)
            addCursorRect(CGRect(x: frame.minX - band, y: frame.minY, width: band, height: frame.height), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: frame.maxX, y: frame.minY, width: band, height: frame.height), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: band), cursor: .resizeUpDown)
            for corner in [CGPoint(x: frame.minX - band, y: frame.minY - band), CGPoint(x: frame.maxX, y: frame.minY - band),
                           CGPoint(x: frame.minX - band, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)] {
                addCursorRect(CGRect(origin: corner, size: CGSize(width: band, height: band)), cursor: .crosshair)
            }
        }
    }
}

/// The canvas camera on the render server (chrome-parity R2; on with
/// `motion.renderServer`): ``ScreenContentView/springCanvasCameraOnRenderServer()``.
struct CanvasRenderMotion: RenderServerMotion {
    var kind: RenderMotionKind { .canvas }

    func begin(on screen: ScreenContentView, policy: MotionPolicy) -> MotionBackend {
        screen.springCanvasCameraOnRenderServer() ? .renderServer : .cpuStep
    }
}
