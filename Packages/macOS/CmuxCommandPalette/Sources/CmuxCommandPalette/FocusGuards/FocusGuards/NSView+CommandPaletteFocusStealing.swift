public import AppKit
internal import CmuxFoundation

public extension NSView {
    /// Whether this view, or any view in its superview chain, is a terminal-surface
    /// or browser view that must not be allowed to reclaim first-responder focus while
    /// the command palette is visible.
    ///
    /// A view counts as focus-stealing when it (or an ancestor) conforms to the
    /// `FocusStealingResponder` marker. In the executable app target the terminal
    /// surface views and the embedded web view conform to that marker, so this walk
    /// never has to know the concrete terminal/browser view types.
    var commandPaletteFocusStealingSurfaceInViewHierarchy: Bool {
        if self is any FocusStealingResponder {
            return true
        }
        var current: NSView? = superview
        while let candidate = current {
            if candidate is any FocusStealingResponder {
                return true
            }
            current = candidate.superview
        }
        return false
    }
}
