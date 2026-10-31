import AppKit
import CmuxNextDesign

/// A screen shown as a canvas (plans/cmux-next/canvas-layout.md). The camera is
/// the view's bounds: AppKit scales drawing, hit testing and every
/// `convert(_:from:)` for it, so hosts, rings, drops and page windows follow it
/// with no camera math of their own. The empty canvas pans with a drag; the
/// band around each pane moves (above it) or resizes (sides and corners) it.
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
            canvasState.modelCamera = nil
            canvasState.drag = nil
            if modeChanged { window?.invalidateCursorRects(for: self) }
            return !modeChanged
        }
        if canvas.camera != canvasState.modelCamera {
            canvasState.modelCamera = canvas.camera
            // A window not on screen (or Reduce Motion) shows the new camera at once.
            canvasState.camera.retarget(canvas.camera, animated: animated && !entering && !context.reduceMotion && window?.isVisible == true)
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
        let size = frame.size
        guard size.width > 0, size.height > 0 else { return }
        let target = canvasState.canvas != nil ? canvasState.camera.shown.visibleRect(viewport: size) : CGRect(origin: .zero, size: size)
        guard bounds != target else { return }
        // AppKit reports a bounds size change as a backing change: it must not reconcile (Crash D).
        isApplyingCamera = true
        defer { isApplyingCamera = false }
        if bounds.size != target.size { setBoundsSize(target.size) }
        if bounds.origin != target.origin { setBoundsOrigin(target.origin) }
        if canvasState.canvas != nil { context.model.reportCanvasViewport(size, for: screenID) }
        context.overlayNeedsSync()
    }

    /// Puts the camera at its target now (the window went out of sight: no frames).
    func settleCanvasCamera() {
        guard isCanvas, canvasState.camera.isMoving else { return }
        canvasState.camera.snap()
        applyCamera()
    }

    /// Advances the camera toward its target; true while it moves.
    func stepCanvasCamera(_ dt: Double, policy: MotionPolicy) -> Bool {
        guard isCanvas, canvasState.camera.isMoving else { return false }
        let moving = canvasState.camera.advance(dt, parameters: policy.spring(.scroll))
        applyCamera()
        return moving
    }

    /// Hosts stacked in the canvas's order, back to front; other views keep theirs.
    func reconcileCanvasStacking() {
        guard let order = canvasState.canvas?.order else { return }
        let index = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ranks = subviews.enumerated().map { position, view in
            ((view as? PaneHostView).flatMap { index[$0.pane] } ?? order.count) * 100_000 + position
        }
        guard ranks != ranks.sorted() else { return }
        let table = StackingTable(ranks: Dictionary(uniqueKeysWithValues: zip(subviews.map(ObjectIdentifier.init), ranks)))
        withExtendedLifetime(table) {
            sortSubviews(compareStacking, context: Unmanaged.passUnretained(table).toOpaque())
        }
    }

    // MARK: Trackpad

    /// Pans the camera with the pointer (`delta` screen points, natural direction). Live; `ended` reports it.
    func canvasPan(by delta: CGSize, ended: Bool) {
        guard isCanvas else { return }
        if delta != .zero {
            canvasState.camera.retarget(canvasState.camera.shown.panned(byScreenDelta: delta), animated: false)
            applyCamera()
        }
        if ended { reportCamera() }
    }

    /// Zooms by `factor` about `windowPoint` (a pinch). Live; `ended` reports it.
    func canvasMagnify(by factor: CGFloat, at windowPoint: NSPoint, ended: Bool) {
        guard isCanvas else { return }
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
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = canvasState.drag else { return super.mouseDragged(with: event) }
        switch drag {
        case let .pane(pane, origin):
            let zoom = canvasState.camera.shown.zoom
            // Window points grow up; canvas points grow down.
            let translation = CGSize(width: (event.locationInWindow.x - origin.x) / zoom, height: (origin.y - event.locationInWindow.y) / zoom)
            context.model.setCanvasFrame(pane.frame(translation: translation), for: pane.pane)
        case let .pan(origin, from):
            let delta = CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y)
            canvasState.camera.retarget(from.panned(byScreenDelta: delta), animated: false)
            applyCamera()
        }
        context.requestFrames()
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = canvasState.drag else { return super.mouseUp(with: event) }
        canvasState.drag = nil
        switch drag {
        case .pane:
            context.model.setGestureActive(false)
        case .pan:
            reportCamera()
        }
        window?.invalidateCursorRects(for: self)
    }

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
