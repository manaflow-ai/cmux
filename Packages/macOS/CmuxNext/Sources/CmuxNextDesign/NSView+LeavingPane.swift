public import AppKit
import CmuxNextDesignTokens

extension NSView {
    /// Whether this view is in a pane that left its layout in a change that has not shown yet: the first pane host at
    /// or above the view says so (`PaneLeaving`). False with no such host.
    ///
    /// Such a pane shows at its old place until that change shows (a close's move, a zoom of another pane), and
    /// another pane can be over it. A walk over a window's views that looks for the pane or the page at a place asks
    /// this, so that it does not answer a pane that has left. The pane host's own hit test refuses such a pane too.
    public var isInALeavingPane: Bool {
        var view: NSView? = self
        while let current = view {
            if let host = current as? any PaneLeaving { return host.isLeaving }
            view = current.superview
        }
        return false
    }
}
