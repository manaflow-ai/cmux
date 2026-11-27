public import AppKit

/// A view a toast must never cover (the Home composer and its buttons).
/// The toast host lifts each toast above every such view in its window
/// whose rect lies under the toast, and moves shown toasts when the view
/// calls ``CmuxToastAvoidance/avoidanceChanged(in:)`` for its window.
@MainActor
public protocol CmuxToastAvoiding: NSView {
    /// The rect toasts stay clear of, in the view's own coordinates.
    var toastAvoidanceRect: NSRect { get }
}
