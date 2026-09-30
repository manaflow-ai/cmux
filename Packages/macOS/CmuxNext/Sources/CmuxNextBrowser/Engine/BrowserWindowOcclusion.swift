public import AppKit
public import Foundation

/// Implemented by a window that has its own native overlays taking the
/// mouse over its content (split dividers, the screen switcher). Pages that
/// are child windows (`.childWindow`) leave those rects uncovered: they are
/// masked there and the mouse goes to the window.
@MainActor
public protocol BrowserWindowOcclusionProviding: AnyObject {
    /// Rects in window coordinates.
    var browserOcclusionRectsInWindow: [CGRect] { get }
}

public enum BrowserChildWindowPages {
    /// Post (object: the `NSWindow`) to make every child-window page of that
    /// window re-apply its geometry, clip and occlusion: when
    /// ``BrowserWindowOcclusionProviding/browserOcclusionRectsInWindow``
    /// changes, and after the window moved or resized by any means (drag,
    /// Accessibility clients such as Rectangle, display or Space changes,
    /// fullscreen, deminiaturize).
    public static let needsUpdate = Notification.Name("CmuxBrowserChildWindowPagesNeedUpdate")
}
