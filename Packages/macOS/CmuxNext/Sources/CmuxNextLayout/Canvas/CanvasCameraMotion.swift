import CmuxNextDesign
import CoreGraphics

/// The camera a canvas screen shows now, on springs toward its target: an
/// action's zoom or reveal moves there, a pan or a pinch snaps with the pointer.
nonisolated struct CanvasCameraMotion: Hashable, Sendable {
    private var x = SpringValue(0), y = SpringValue(0), zoom = SpringValue(1)

    /// The camera shown this frame.
    var shown: CanvasCamera { CanvasCamera(center: CGPoint(x: x.value, y: y.value), zoom: zoom.value) }
    /// The camera it moves to.
    var target: CanvasCamera { CanvasCamera(center: CGPoint(x: x.target, y: y.target), zoom: zoom.target) }
    /// Still moving toward the target.
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
}
