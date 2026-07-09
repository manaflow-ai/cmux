public import AppKit

/// The right-sidebar dock keyboard-focus endpoint (the `.dock` mode).
///
/// The app-side `DockKeyboardFocusView` conforms. The main-window focus
/// controller routes dock host/first-item focus and responder-ownership queries
/// through this seam instead of the concrete view type.
@MainActor
public protocol DockFocusHosting: AnyObject {
    /// Whether `responder` is owned by this dock host (the host itself or a
    /// right-sidebar dock terminal surface).
    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool

    /// Requests keyboard focus on the dock's first control.
    func focusFirstItemFromCoordinator()

    /// Makes the dock host (or its first control) first responder. Returns
    /// whether focus was taken.
    func focusHostFromCoordinator() -> Bool
}
