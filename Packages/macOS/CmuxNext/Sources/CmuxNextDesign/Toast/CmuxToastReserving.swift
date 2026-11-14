public import AppKit

/// A view whose newest content stays in sight above the toasts (the Home chat's transcript).
///
/// Toasts sit bottom-center over their window, clear of the views they avoid
/// (``CmuxToastAvoiding``, the message box) and over whatever is above them. A view that
/// reserves room is told, whenever its window's toasts settle (one shows, goes, grows with
/// its Details or moves clear of an avoided view), the rect they take, and keeps its newest
/// content above it in the toasts' own motion, so a toast never covers a message.
@MainActor
public protocol CmuxToastReserving: NSView {
    /// The toasts over this view's window settled.
    ///
    /// - Parameters:
    ///   - rect: The union of the shown toasts' frames, in window coordinates; nil when none
    ///     shows.
    ///   - duration: Seconds the toasts take to get there (their move); 0 when they move at once
    ///     (Reduce Motion, animations off). The view moves its content over the same time.
    func toastsSettled(in rect: NSRect?, duration: TimeInterval)
}
