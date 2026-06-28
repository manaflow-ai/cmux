public import AppKit

extension NSView {
    /// The immediate child of this view whose own subtree contains `descendant`,
    /// or `nil` when `descendant` is not a descendant of the receiver. Walks up
    /// from `descendant` through its superview chain, remembering the last view
    /// seen before the receiver is reached; that view is the direct child whose
    /// subtree the descendant lives in. Used to pair a hosted inspector with the
    /// sibling page view that shares its container.
    public func directChild(containing descendant: NSView) -> NSView? {
        var current: NSView? = descendant
        var directChild: NSView?
        while let view = current, view !== self {
            directChild = view
            current = view.superview
        }
        guard current === self else { return nil }
        return directChild
    }
}
