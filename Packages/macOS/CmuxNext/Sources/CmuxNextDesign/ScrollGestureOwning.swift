public import AppKit

/// A view that can take a trackpad scroll gesture away from the views inside it: the layout,
/// whose Command + scroll moves columns and rows over any pane (`layout.scrollModifier`).
///
/// The owning view decides once per gesture, at its first event, and is the one place that
/// decision lives. Content inside it that reacts to the same gesture on its own (a Chromium
/// page's swipe Back or Forward, which watches scroll events before the page does) asks
/// ``NSView/isScrollGestureTakenByEnclosingView`` instead of testing the modifier keys itself, so
/// the two never disagree about who owns a gesture.
///
/// ```swift
/// // CEFSwipeNavigation, before it starts a swipe:
/// guard !hostView.isScrollGestureTakenByEnclosingView else { return event }
/// ```
@MainActor
public protocol ScrollGestureOwning: NSView {
    /// Whether this view took the current trackpad gesture for itself.
    ///
    /// True from the gesture's deciding event (its touch, or its `began` when no touch came
    /// first) until its end, for a gesture this view moves or keeps; false for a gesture it
    /// passes to the content under the pointer, and between gestures. Read on the main thread
    /// from scroll event monitors: answer from state you already have.
    var ownsCurrentScrollGesture: Bool { get }
}

public extension NSView {
    /// Whether the nearest enclosing ``ScrollGestureOwning`` view took the current trackpad
    /// gesture (false when there is none). Walks the superview chain only.
    var isScrollGestureTakenByEnclosingView: Bool {
        var ancestor = superview
        while let view = ancestor {
            if let owner = view as? any ScrollGestureOwning { return owner.ownsCurrentScrollGesture }
            ancestor = view.superview
        }
        return false
    }
}
