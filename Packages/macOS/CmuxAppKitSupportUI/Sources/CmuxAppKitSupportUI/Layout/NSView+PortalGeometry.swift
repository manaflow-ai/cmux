public import AppKit

public extension NSView {
    /// Whether this view, or any of its ancestors, is currently hidden.
    ///
    /// Walks `superview` from this view to the window's root, returning `true`
    /// at the first hidden node. The window/browser portals use this to decide
    /// whether a hosted overlay should be presented: a view buried under a
    /// hidden ancestor is not on screen even if its own `isHidden` is `false`.
    /// The walk is a pure read of `isHidden` along the ancestor chain and holds
    /// no portal state.
    var isHiddenOrAncestorHidden: Bool {
        if isHidden { return true }
        var current = superview
        while let view = current {
            if view.isHidden { return true }
            current = view.superview
        }
        return false
    }

    /// Whether this view is ordered above `reference` among `container`'s direct
    /// subviews (later in `container.subviews` draws on top).
    ///
    /// Returns `false` when either view is not a direct subview of `container`.
    /// The portals use this to keep a hosted page/overlay layered correctly
    /// relative to its anchor before reordering subviews. Pure index comparison
    /// over `container.subviews`; carries no host-view identity.
    /// - Parameters:
    ///   - reference: The sibling to compare against.
    ///   - container: The shared parent whose subview order defines z-order.
    /// - Returns: `true` when this view's index is greater than `reference`'s.
    func isAbove(_ reference: NSView, in container: NSView) -> Bool {
        guard let viewIndex = container.subviews.firstIndex(of: self),
              let referenceIndex = container.subviews.firstIndex(of: reference) else {
            return false
        }
        return viewIndex > referenceIndex
    }

    /// Snaps `rect` to whole device pixels using this view's backing scale.
    ///
    /// Non-finite rectangles are returned unchanged. The scale is the view's
    /// `window?.backingScaleFactor`, falling back to the main screen's, clamped
    /// to at least `1.0`; each edge is rounded to the nearest device pixel
    /// (ties away from zero) and the size is clamped non-negative. The portals
    /// apply this before assigning a hosted frame so a converted SwiftUI/AppKit
    /// rectangle lands on pixel boundaries instead of producing blurry, jittery
    /// subpixel layout during geometry sync. Pure transform; reads only the
    /// view's backing scale.
    /// - Parameter rect: The rectangle to snap, in any coordinate space.
    /// - Returns: The pixel-snapped rectangle, or `rect` unchanged when it is
    ///   not finite.
    func pixelSnapped(_ rect: NSRect) -> NSRect {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite else {
            return rect
        }
        let scale = max(1.0, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        return NSRect(
            x: snap(rect.origin.x),
            y: snap(rect.origin.y),
            width: max(0, snap(rect.size.width)),
            height: max(0, snap(rect.size.height))
        )
    }
}

public extension NSRect {
    /// Whether this rectangle equals `other` within `epsilon` on every edge.
    ///
    /// Compares origin x/y and size width/height independently against
    /// `epsilon`. The window/browser portals use this to skip no-op frame
    /// assignments during geometry sync, where converted rectangles drift by
    /// subpixel amounts between layout passes. Pure value comparison.
    /// - Parameters:
    ///   - other: The rectangle to compare against.
    ///   - epsilon: The per-component tolerance (default `0.01`).
    /// - Returns: `true` when all four components differ by at most `epsilon`.
    func isApproximatelyEqual(to other: NSRect, epsilon: CGFloat = 0.01) -> Bool {
        abs(origin.x - other.origin.x) <= epsilon &&
            abs(origin.y - other.origin.y) <= epsilon &&
            abs(size.width - other.size.width) <= epsilon &&
            abs(size.height - other.size.height) <= epsilon
    }
}
