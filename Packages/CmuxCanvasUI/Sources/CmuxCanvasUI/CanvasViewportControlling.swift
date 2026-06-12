public import Foundation

/// Viewport operations the canvas view exposes to the host's action
/// executors.
///
/// ``CanvasModel`` holds a weak reference to the attached view through this
/// seam so the host's shortcuts, palette, and automation verbs can drive the
/// viewport without referencing the concrete view.
@MainActor
public protocol CanvasViewportControlling: AnyObject {
    /// Scrolls the pane fully into view (minimal scroll, with margin).
    func revealPane(_ panelId: UUID, animated: Bool)
    /// Toggles between fit-all overview magnification and the previous zoom.
    func toggleOverview()
    /// Multiplies the magnification by `factor` (clamped), anchored at the
    /// viewport center.
    func zoom(by factor: CGFloat)
    /// Returns to 100% magnification, anchored at the viewport center.
    func resetZoom()
    /// Re-reads the model after an external mutation (palette command,
    /// automation verb) and animates pane views to their new frames.
    func modelDidChangeExternally(animated: Bool)
}
