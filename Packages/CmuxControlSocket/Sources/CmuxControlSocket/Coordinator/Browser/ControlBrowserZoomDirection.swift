/// The validated `browser.zoom.set` direction.
public enum ControlBrowserZoomDirection: Sendable, Equatable {
    /// `"in"` → `zoomIn()`.
    case zoomIn
    /// `"out"` → `zoomOut()`.
    case zoomOut
    /// `"reset"` → `resetZoom()`.
    case reset
}
