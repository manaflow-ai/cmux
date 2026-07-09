import AppKit

extension NSView {
    /// Every descendant of this view, gathered by an iterative depth-first walk
    /// that visits each subview level front-to-back (the reversed subview order),
    /// so callers see nearer views before the ones they sit in front of. The
    /// receiver itself is not included.
    ///
    /// Kept package-internal so it does not collide with the public
    /// `NSView.visibleDescendants` that `CmuxAppKitSupportUI` exposes to the app
    /// target, which the browser domain package cannot depend on upward. Used by
    /// `HostedInspectorDividerFinder` to enumerate hosted inspector candidates.
    var visibleDescendants: [NSView] {
        var descendants: [NSView] = []
        var stack = Array(subviews.reversed())
        while let view = stack.popLast() {
            descendants.append(view)
            stack.append(contentsOf: view.subviews.reversed())
        }
        return descendants
    }
}
