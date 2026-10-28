import AppKit
import CmuxNextWakeups

/// What a screen view keeps while it shows a canvas (ScreenContentView+Canvas):
/// the canvas from the model, the camera on its springs, and a pointer drag.
struct ScreenCanvasState {
    /// A pointer drag on the canvas.
    enum Drag {
        /// A pane's move or resize band; `origin` is the pointer's window point at the start.
        case pane(CanvasPaneDrag, origin: CGPoint)
        /// The empty canvas: the camera follows the pointer.
        case pan(origin: CGPoint, from: CanvasCamera)
    }

    /// The canvas shown; nil shows the daemon layout.
    var canvas: CanvasScreen?
    /// The model camera last applied: a sync retargets only on a newer one, so a
    /// pan in progress keeps the camera the pointer moved.
    var modelCamera: CanvasCamera?
    var camera = CanvasCameraMotion()
    var drag: Drag?
    /// The drag's moves on its window's coalescer, from mouse-down to mouse-up (feature
    /// `pointerFrameDrags`); nil: each drag event moves at once.
    var dragFrames: PointerFrameConsumer?

    /// Handle band width on screen, at every zoom.
    static let handleThickness: CGFloat = 8
}
