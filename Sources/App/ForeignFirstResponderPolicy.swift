import AppKit

/// Whether an active terminal surface should *yield* to `firstResponder` instead of taking first
/// responder itself when reconciling focus (used by `GhosttySurfaceScrollView.ensureFocus` and the
/// find-overlay focus apply).
///
/// A terminal yields only to a *legitimate* in-window focus owner: a focused text editor
/// (`NSText` field editor) or a right-sidebar / dock / feed host. Crucially it must also still
/// belong to `window`. cmux hosts terminal surfaces through a portal that reparents views between
/// windows; a focus owner can be reparented out of a window without resigning, leaving
/// `window.firstResponder` pointing at a view that no longer belongs to the window (a "stranded"
/// responder, see issue #5269). The previous guard checked responder *type* only, so it treated a
/// stranded `NSText` / sidebar responder as legitimate and the terminal never reclaimed focus —
/// making the pane unfocusable by click or by programmatic `focus-pane` until the workspace was
/// moved to a fresh window. Requiring window membership lets the terminal reclaim focus from a
/// stranded responder while still respecting a genuine in-window focus owner.
///
/// - Parameters:
///   - firstResponder: The window's current first responder.
///   - window: The window whose focus is being reconciled.
///   - isRightSidebarOwner: Predicate identifying right-sidebar / dock / feed focus hosts (injected
///     so this policy is testable without `AppDelegate`).
/// - Returns: `true` only when `firstResponder` is a legitimate focus owner that genuinely belongs
///   to `window`; `false` when the terminal should reclaim first responder (including when the
///   responder is stranded in another window or detached).
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
    // A focused text editor that `window` hosts is being edited by the user, so the terminal must yield
    // the keystroke. `NSText` covers AppKit field editors AND SwiftUI's private `_SystemTextFieldFieldEditor`
    // (an `NSText` subclass — verified at runtime: the icon-picker field editor logs `isnst=1`).
    //
    // The editor counts as hosted by `window` when its backing window is `window` itself OR a child
    // window `window` presents. SwiftUI hosts a popover/palette overlay's field editor in a separate
    // `_NSPopoverWindow` whose `parent` chain reaches `window` (verified: chain `[popover, main]`,
    // `isChildOfWin=1`), even though it is `window`'s active first responder — so the strict
    // `.window === window` guard rejected it and keyRepair stole the keystroke. Walking the parent
    // chain (rather than accepting any window) keeps the #5269 guarantee: a text editor stranded in an
    // unrelated window, or fully detached (`window == nil`), never reaches `window` and is reclaimed.
    if firstResponder is NSText {
        var hostWindow = (firstResponder as? NSView)?.window
        var hops = 0
        while let current = hostWindow, hops < 8 {
            if current === window {
                return true
            }
            hostWindow = current.parent
            hops += 1
        }
    }
    // Non-text focus owners (right-sidebar / dock / feed hosts) must still belong to this window: a
    // stranded host reparented into another window without resigning must not block the terminal from
    // reclaiming first responder (issue #5269).
    guard (firstResponder as? NSView)?.window === window else { return false }
    return isRightSidebarOwner(firstResponder)
}
