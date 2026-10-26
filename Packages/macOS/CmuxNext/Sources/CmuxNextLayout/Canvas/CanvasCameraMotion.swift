import CmuxNextDesign
import CoreGraphics

/// The camera a canvas screen shows now, on springs toward its target: an
/// action's zoom or reveal moves there, a pan or a pinch snaps with the pointer.
///
/// The main thread steps the springs (`ScreenContentView.stepCanvasCamera`), or, with
/// `motion.renderServer` on, Core Animation runs them (``handToRenderServer(at:axes:parameters:)``)
/// and this value keeps their closed form (``CanvasCameraRenderSpring``), so a later change starts
/// from what shows with no presentation-layer read.
nonisolated struct CanvasCameraMotion: Hashable, Sendable {
    private var x = SpringValue(0), y = SpringValue(0), zoom = SpringValue(1)
    /// The springs Core Animation runs toward ``target``; nil while it runs none.
    private(set) var onRenderServer: CanvasCameraRenderSpring?

    /// The camera the main thread shows: the target while the render server springs to it.
    var shown: CanvasCamera { CanvasCamera(center: CGPoint(x: x.value, y: y.value), zoom: zoom.value) }
    /// The camera it moves to.
    var target: CanvasCamera { CanvasCamera(center: CGPoint(x: x.target, y: y.target), zoom: zoom.target) }
    /// The main thread still steps toward the target.
    var isMoving: Bool { [x, y, zoom].contains { $0.value != $0.target || $0.velocity != 0 } }

    /// Moves toward `camera`, or shows it at once.
    mutating func retarget(_ camera: CanvasCamera, animated: Bool) {
        x.target = camera.center.x
        y.target = camera.center.y
        zoom.target = camera.zoom
        if !animated { snap() }
    }

    /// Shows the target at once.
    mutating func snap() {
        x.snap(); y.snap(); zoom.snap()
    }

    /// Advances by `dt`; true while it still moves.
    mutating func advance(_ dt: Double, parameters: SpringParameters) -> Bool {
        let a = x.advance(dt, parameters: parameters, epsilon: 0.25)
        let b = y.advance(dt, parameters: parameters, epsilon: 0.25)
        let c = zoom.advance(dt, parameters: parameters, epsilon: 0.0005)
        return a || b || c
    }

    // MARK: Render server

    /// What the main thread's springs show and how fast.
    var state: CanvasCameraState {
        CanvasCameraState(center: CGPoint(x: x.value, y: y.value), zoom: zoom.value,
                          centerRate: CGPoint(x: x.velocity, y: y.velocity), zoomRate: zoom.velocity)
    }

    /// What the screen shows at `time` (the screen layer's clock): the render server's springs while
    /// they run, else the main thread's.
    func shown(at time: Double) -> CanvasCameraState {
        onRenderServer?.shown(at: time) ?? state
    }

    /// The render server takes the move to ``target`` at `time`, from what shows then and at its speed;
    /// the main thread's springs rest at the target. `axes`: the screen layer's units per canvas point,
    /// with the view's bounds at the target. Returns the springs to add.
    mutating func handToRenderServer(at time: Double, axes: RenderLayerAxes, parameters: SpringParameters) -> CanvasCameraRenderSpring.Added {
        let shown = shown(at: time)
        var springs = onRenderServer ?? CanvasCameraRenderSpring(rest: target, axes: axes)
        let added = springs.retarget(to: target, axes: axes, shown: shown, at: time, parameters: parameters)
        snap()
        onRenderServer = springs
        return added
    }

    /// The main thread takes the render server's springs back at `time`: its own start from what shows
    /// then, at that speed, toward the same target. Returns false when the render server runs none.
    mutating func takeBackFromRenderServer(at time: Double) -> Bool {
        guard let springs = onRenderServer else { return false }
        onRenderServer = nil
        let shown = springs.shown(at: time)
        x.value = shown.center.x
        y.value = shown.center.y
        zoom.value = shown.zoom
        x.velocity = shown.centerRate.x
        y.velocity = shown.centerRate.y
        zoom.velocity = shown.zoomRate
        return true
    }

    /// The render server's springs stopped: it landed at the target, or the screen left canvas mode.
    mutating func renderServerStopped() {
        onRenderServer = nil
    }
}

/// A camera as it shows at one time and how fast it moves: canvas points and zoom, per second. The
/// zoom is not clamped, so a spring's overshoot carries over.
nonisolated struct CanvasCameraState: Hashable, Sendable {
    var center: CGPoint
    var zoom: Double
    var centerRate: CGPoint
    var zoomRate: Double
}
