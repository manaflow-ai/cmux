public import AppKit

/// A window that keeps a ``WindowZoom`` and ends its running animation when the resize finishes.
@MainActor
public protocol WindowZoomFinishing: AnyObject {
    /// The zoom animation `generation` finished (``WindowZoom/end(_:)``).
    func windowZoomFinished(_ generation: Int)
}

/// The window a zoom's completion reaches back to (weak: a window closed mid-zoom is gone).
/// Main-actor isolated, so the `@MainActor @Sendable` completion can hold it.
@MainActor
final class WindowZoomCompletion {
    weak var window: (NSWindow & WindowZoomFinishing)?

    init(window: NSWindow) {
        self.window = window as? NSWindow & WindowZoomFinishing
    }
}
