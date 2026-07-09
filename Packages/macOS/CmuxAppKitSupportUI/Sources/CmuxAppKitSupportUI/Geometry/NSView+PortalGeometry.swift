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

    /// Convert this anchor view's bounds to window coordinates while honoring
    /// ancestor clipping. SwiftUI/AppKit hosting layers can report an anchor
    /// bounds wider than its split pane when intrinsic-size content overflows;
    /// intersecting through each finite ancestor bounds gives the effective
    /// visible rect that should drive portal geometry. The walk stops after
    /// intersecting `stopView` (the portal's installed reference view), or at the
    /// top of the superview chain. Returns `.zero` once the running intersection
    /// becomes null.
    public func effectiveAnchorFrameInWindow(stoppingAt stopView: NSView?) -> NSRect {
        var frameInWindow = convert(bounds, to: nil)
        var current = superview
        while let ancestor = current {
            let ancestorBoundsInWindow = ancestor.convert(ancestor.bounds, to: nil)
            let finiteAncestorBounds = ancestorBoundsInWindow.hasFiniteComponents
            if finiteAncestorBounds {
                frameInWindow = frameInWindow.intersection(ancestorBoundsInWindow)
                if frameInWindow.isNull { return .zero }
            }
            if ancestor === stopView { break }
            current = ancestor.superview
        }
        return frameInWindow
    }
}
