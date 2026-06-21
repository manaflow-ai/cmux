public import CoreGraphics

/// Where a freshly created main window should be placed relative to the window
/// it was opened from.
///
/// A pure `Sendable` value the app target maps onto an `NSWindow` call:
/// ``frame(_:)`` becomes `window.setFrame(_:display:false)` and ``center``
/// becomes `window.center()`. Keeping the decision in a value type lets the
/// cascade-offset math be lifted out of the app target and unit-tested without
/// AppKit.
public enum NewWindowCascadePlacement: Sendable, Equatable {
    /// Center the new window on the active screen (the source screen could not
    /// be resolved, so there is no frame to cascade against).
    case center
    /// Place the new window at this frame (already cascaded off the source and
    /// clamped onto the source screen's visible area).
    case frame(CGRect)
}
