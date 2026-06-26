public import AppKit

extension NSView {
    /// Whether the view is hidden, or any of its ancestors up the superview
    /// chain is hidden (an effectively-invisible view even when `isHidden` is
    /// false on the view itself).
    public var isHiddenOrAncestorHidden: Bool {
        if isHidden { return true }
        var current = superview
        while let v = current {
            if v.isHidden { return true }
            current = v.superview
        }
        return false
    }

    /// The view's frame expressed in its window's base coordinate space, or
    /// `nil` when the view is not currently in a window. Prefers the view's
    /// frame as laid out by its superview, because some AppKit views (notably
    /// scroll views) can temporarily report stale bounds during reparenting.
    public var frameInWindow: CGRect? {
        guard window != nil else { return nil }
        if let superview {
            return superview.convert(frame, to: nil)
        }
        return convert(bounds, to: nil)
    }

    /// Whether `self` is ordered above `reference` in `container`'s subview
    /// stack (i.e. drawn later, so on top). Returns false if either view is not
    /// a direct subview of `container`.
    public func isOrdered(above reference: NSView, in container: NSView) -> Bool {
        guard let viewIndex = container.subviews.firstIndex(of: self),
              let referenceIndex = container.subviews.firstIndex(of: reference) else {
            return false
        }
        return viewIndex > referenceIndex
    }
}
