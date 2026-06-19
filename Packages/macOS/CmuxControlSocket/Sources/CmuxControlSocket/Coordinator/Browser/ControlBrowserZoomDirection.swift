internal import Foundation

/// The validated `direction` of `browser.zoom.set`. The coordinator validates
/// the raw string against `in`/`out`/`reset`; the witness applies it. The raw
/// `direction` string is echoed by the coordinator into the payload.
public enum ControlBrowserZoomDirection: String, Sendable, Equatable {
    /// Increase zoom (`zoomIn`).
    case zoomIn = "in"
    /// Decrease zoom (`zoomOut`).
    case zoomOut = "out"
    /// Reset to default zoom (`resetZoom`).
    case reset
}
