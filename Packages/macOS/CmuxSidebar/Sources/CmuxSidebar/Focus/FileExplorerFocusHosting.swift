public import AppKit

/// The right-sidebar file-explorer keyboard-focus endpoint, used for both the
/// `.files` (outline) and `.find` (search) modes.
///
/// The app-side `FileExplorerContainerView` conforms. The main-window focus
/// controller registers one instance per mode and routes outline/search-field
/// focus and responder-ownership queries through this seam instead of the
/// concrete view type.
@MainActor
public protocol FileExplorerFocusHosting: AnyObject {
    /// Which right-sidebar mode (`.files` or `.find`) this host currently
    /// represents, used to bucket the registered host on attach.
    func representedRightSidebarMode() -> RightSidebarMode

    /// Whether `responder` is owned by this file-explorer host (outline, search
    /// results, search field, or field editor).
    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool

    /// Moves keyboard focus to the file-explorer outline. Returns whether focus
    /// was taken.
    func focusOutline() -> Bool

    /// Moves keyboard focus to the file-explorer search field. Returns whether
    /// focus was taken.
    func focusSearchField() -> Bool
}
