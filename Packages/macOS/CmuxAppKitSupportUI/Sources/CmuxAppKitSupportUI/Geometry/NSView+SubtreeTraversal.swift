public import AppKit

extension NSView {
    /// Every descendant of this view, gathered by an iterative depth-first walk
    /// that visits each subview level front-to-back (the reversed subview order),
    /// so callers see nearer views before the ones they sit in front of. The
    /// receiver itself is not included.
    public var visibleDescendants: [NSView] {
        var descendants: [NSView] = []
        var stack = Array(subviews.reversed())
        while let view = stack.popLast() {
            descendants.append(view)
            stack.append(contentsOf: view.subviews.reversed())
        }
        return descendants
    }
}
