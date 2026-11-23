import CoreGraphics

/// Which view under a touch has its own use for a drag (design/gesture-matrix.md): the innermost
/// view that can use a gesture owns it, so a parent recognizer (a row's swipe actions, the team
/// drawer, the back swipe) asks here where its touch started before it begins.
public enum TouchOwnership {
    /// Whether a horizontal scroller can still move its content for a finger moving sideways by
    /// `fingerDX` (negative: leftward, the content moves toward its trailing end). A scroller at
    /// that end leaves the drag to its container, as a list at its top leaves a sheet's drag.
    public static func scrollerTakes(fingerDX: CGFloat, offsetX: CGFloat, contentWidth: CGFloat,
                                     boundsWidth: CGFloat, insetLeft: CGFloat = 0, insetRight: CGFloat = 0) -> Bool {
        let minX = -insetLeft
        let maxX = max(minX, contentWidth + insetRight - boundsWidth)
        guard maxX - minX > 1 else { return false }
        if fingerDX < 0 { return offsetX < maxX - 0.5 }
        if fingerDX > 0 { return offsetX > minX + 0.5 }
        return true
    }

    /// A drag's sideways travel away from the leading edge, where a leading drawer opens from:
    /// rightward in a left-to-right layout, leftward in a right-to-left one. Row swipe actions are
    /// semantic (trailing), so the drawer must be too, or a right-to-left row's trailing swipe
    /// also opens the drawer.
    public static func fromLeading(_ physicalDX: CGFloat, rightToLeft: Bool) -> CGFloat {
        rightToLeft ? -physicalDX : physicalDX
    }
}

#if os(iOS)
import UIKit

@MainActor
public extension TouchOwnership {
    /// Where a recognizer's touch began, in `view`'s coordinates (a window included). A pan asked
    /// to begin has already moved past its slop: its start is its location less its translation.
    static func startPoint(of recognizer: UIGestureRecognizer, in view: UIView?) -> CGPoint {
        let now = recognizer.location(in: view)
        guard let pan = recognizer as? UIPanGestureRecognizer else { return now }
        let moved = pan.translation(in: view)
        return CGPoint(x: now.x - moved.x, y: now.y - moved.y)
    }

    /// The touched view and its superviews, up to (not including) `root`.
    static func chain(from hit: UIView?, upTo root: UIView?) -> [UIView] {
        var views: [UIView] = []
        var view = hit
        while let current = view, current !== root {
            views.append(current)
            view = current.superview
        }
        return views
    }

    /// Text being edited (a first-responder text view or field) at or above `hit`: it owns every
    /// drag that starts on it (a caret or selection drag, a long draft's scroll).
    static func isEditingText(from hit: UIView?, upTo root: UIView?) -> Bool {
        chain(from: hit, upTo: root).contains { ($0 is UITextView || $0 is UITextField) && $0.isFirstResponder }
    }

    /// The innermost scroll view at or above `hit` that is wider than its bounds (code, a wide
    /// table, a chip row).
    static func wideScroller(from hit: UIView?, upTo root: UIView?) -> UIScrollView? {
        for view in chain(from: hit, upTo: root) {
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled,
               scroll.contentSize.width > scroll.bounds.width + 1 {
                return scroll
            }
        }
        return nil
    }

    /// Whether a sideways drag by `fingerDX` that started on `hit` belongs to the view it started
    /// on: text being edited, or a scroller that can still scroll that way.
    static func ownsHorizontalDrag(from hit: UIView?, upTo root: UIView?, fingerDX: CGFloat) -> Bool {
        let views = chain(from: hit, upTo: root)
        if views.contains(where: { ($0 is UITextView || $0 is UITextField) && $0.isFirstResponder }) { return true }
        for case let scroll as UIScrollView in views where scroll.isScrollEnabled && scroll.contentSize.width > scroll.bounds.width + 1 {
            let inset = scroll.adjustedContentInset
            if scrollerTakes(fingerDX: fingerDX, offsetX: scroll.contentOffset.x, contentWidth: scroll.contentSize.width,
                             boundsWidth: scroll.bounds.width, insetLeft: inset.left, insetRight: inset.right) {
                return true
            }
        }
        return false
    }
}
#endif
