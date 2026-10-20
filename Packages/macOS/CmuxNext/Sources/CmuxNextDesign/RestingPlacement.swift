public import AppKit

/// A view a layout spring shows away from where it will rest: a pane host
/// while the strip camera scrolls, or a split pane sliding in. Window-relative
/// chrome inside it (a tab strip clearing the traffic lights) measures against
/// the rest, so it lays out once, at its final place, and then moves rigidly
/// with the view instead of laying out again on every frame of the motion.
@MainActor
public protocol RestingPlacement: NSView {
    /// Where the view will rest minus where it shows now, in its superview's points.
    var restOffset: CGVector { get }
}
