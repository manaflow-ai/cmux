public import AppKit

extension NSView {
    /// Whether this view can currently accept right-sidebar keyboard focus.
    ///
    /// A view qualifies only when it is in a window and neither it nor any
    /// ancestor is hidden, and every view from `self` up the superview chain has
    /// a non-degenerate bounds size (width and height both greater than 0.5pt).
    /// A zero-size or hidden link anywhere in the chain means the view is not
    /// actually on screen to take focus, so focus must not fall to it.
    public var cmuxCanAcceptRightSidebarKeyboardFocus: Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        var view: NSView? = self
        while let current = view {
            if current.bounds.width <= 0.5 || current.bounds.height <= 0.5 {
                return false
            }
            view = current.superview
        }
        return true
    }
}
