public import Foundation

/// The seam through which the host app mounts panel content into a canvas
/// pane. The package never sees panel types: the host's descriptor closure
/// mounts content into the pane's container and returns this handle, which
/// the canvas drives for lifecycle and teardown.
@MainActor
public protocol CanvasPaneContentMounting: AnyObject {
    /// Applies the explicit canvas lifecycle state: `false` for panes outside
    /// the render margin (the host pauses rendering, e.g. Ghostty occlusion),
    /// `true` when the pane re-enters. Content size must not change while
    /// not rendering.
    func setRendering(_ rendering: Bool)

    /// Unmounts the content and returns ownership to the host (terminals
    /// re-attach to the window portal system on their next split-mode pass).
    func unmount()
}
