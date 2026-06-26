public import AppKit

/// The right-sidebar fallback keyboard-focus host: the container view that
/// accepts first responder when no per-mode endpoint claims focus.
///
/// The app-side `RightSidebarKeyboardFocusView` conforms. The main-window focus
/// controller holds it weakly through this seam so it no longer depends on the
/// concrete view type. `focusResponder` is the `NSResponder` the controller hands
/// to `NSWindow.makeFirstResponder(_:)` when falling back to the host, and it is
/// the same object used for the controller's `===` identity checks.
@MainActor
public protocol RightSidebarHostFocusing: AnyObject {
    /// The responder to make first responder when focus falls back to this host.
    /// Conformers return `self` (the host view is its own focus responder).
    var focusResponder: NSResponder { get }
}
