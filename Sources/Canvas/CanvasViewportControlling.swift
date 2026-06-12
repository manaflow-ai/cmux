import Foundation

/// Viewport operations the canvas view exposes to action executors.
///
/// `WorkspaceCanvasModel` holds a weak reference to the attached view through
/// this seam so shortcuts, the palette, and socket verbs can drive the
/// viewport without reaching into AppKit types.
@MainActor
protocol CanvasViewportControlling: AnyObject {
    /// Scrolls the pane fully into view (minimal scroll, with margin).
    func revealPane(_ panelId: UUID, animated: Bool)
    /// Toggles between fit-all overview magnification and the previous zoom.
    func toggleOverview()
    /// Re-reads the model after an external mutation (palette command,
    /// socket verb) and animates pane views to their new frames.
    func modelDidChangeExternally(animated: Bool)
}
