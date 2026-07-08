import AppKit

/// Whether an active terminal surface should *yield* to `firstResponder` instead of taking first
/// responder itself when reconciling focus (used by `GhosttySurfaceScrollView.ensureFocus` and the
/// find-overlay focus apply).
///
/// A terminal yields only to a *legitimate* focus owner: a focused text editor (`NSText` field
/// editor) or a right-sidebar / dock / feed host whose window is either `window` or an attached
/// child of `window`. AppKit hosts popover field editors in an `_NSPopoverWindow` child while
/// leaving the main window as key, so child-window membership is the designed arrangement for
/// popover typing.
///
/// cmux hosts terminal surfaces through a portal that reparents views between windows; a focus owner
/// can be reparented out of a window without resigning, leaving `window.firstResponder` pointing at
/// a view that no longer belongs to the window (a "stranded" responder, see issue #5269). Requiring
/// membership in `window` or one of its attached child windows lets the terminal reclaim focus from a
/// stranded responder while still respecting a genuine focus owner.
///
/// - Parameters:
///   - firstResponder: The window's current first responder.
///   - window: The window whose focus is being reconciled.
///   - isRightSidebarOwner: Predicate identifying right-sidebar / dock / feed focus hosts (injected
///     so this policy is testable without `AppDelegate`).
/// - Returns: `true` only when `firstResponder` is a legitimate focus owner that genuinely belongs
///   to `window` or an attached child window; `false` when the terminal should reclaim first
///   responder (including when the responder is stranded in an unrelated window or detached).
///
/// ```swift
/// if respectForeignFirstResponder,
///    let firstResponder = window.firstResponder,
///    shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
///        AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
///    }) {
///     return // a real in-window focus owner is active; do not steal focus
/// }
/// ```
@MainActor
func shouldRespectForeignFirstResponder(
    _ firstResponder: NSResponder,
    in window: NSWindow,
    isRightSidebarOwner: (NSResponder) -> Bool
) -> Bool {
    // A stranded responder (detached, or reparented into another window without resigning) no longer
    // belongs to this window and must not block the terminal from reclaiming first responder.
    guard let responderWindow = (firstResponder as? NSView)?.window,
          window.containsAttachedWindow(responderWindow) else { return false }
    return firstResponder is NSText || isRightSidebarOwner(firstResponder)
}

fileprivate extension NSWindow {
    @MainActor
    func containsAttachedWindow(_ candidate: NSWindow) -> Bool {
        var current: NSWindow? = candidate
        while let window = current {
            if window === self { return true }
            current = window.parent
        }
        return false
    }
}
