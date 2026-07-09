public import AppKit

/// The right-sidebar feed keyboard-focus endpoint (the `.feed` mode).
///
/// The app-side `FeedKeyboardFocusView` conforms. The main-window focus
/// controller routes feed host/first-item focus, responder-ownership queries,
/// and focus-snapshot publication through this seam instead of the concrete view
/// type.
@MainActor
public protocol FeedFocusHosting: AnyObject {
    /// Whether `responder` is owned by this feed host.
    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool

    /// Requests keyboard focus on the feed's first item.
    func focusFirstItemFromCoordinator()

    /// Makes the feed host first responder. Returns whether focus was taken.
    func focusHostFromCoordinator() -> Bool

    /// Pushes the controller's latest feed focus snapshot to the host view.
    func applyFocusSnapshotFromController(_ snapshot: FeedFocusSnapshot)
}
