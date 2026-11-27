/// Wire names for `canvas.zoom` directions, validated at the coordinator so
/// unknown directions fail with `invalid_params` before crossing the seam.
public enum ControlCanvasZoomDirection: String, Sendable, CaseIterable {
    case zoomIn = "in"
    case zoomOut = "out"
    case reset
}
