public import Foundation

/// Implemented by a window that has its own native overlays taking the
/// mouse over its content (split dividers, the screen switcher). Pages that
/// are child windows (`.childWindow`) leave those rects uncovered: they are
/// masked there and the mouse goes to the window. The window asks its pages
/// to re-read these when they change (`NSWindow.updateBrowserPageGeometry`).
@MainActor
public protocol BrowserWindowOcclusionProviding: AnyObject {
    /// Rects in window coordinates.
    var browserOcclusionRectsInWindow: [CGRect] { get }
}
