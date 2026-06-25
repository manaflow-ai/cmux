import AppKit
import CmuxSidebar

/// App-side seam that routes the file explorer's right-sidebar keyboard-focus and
/// mode-shortcut decisions to the active main window, without the file explorer
/// views reaching the `AppDelegate.shared` singleton directly.
///
/// The file explorer (`FileExplorerPanelView` / its `Coordinator` / its AppKit
/// container and table/outline subviews) only knows about this protocol; the
/// concrete conformer is `AppDelegate`, wired in
/// `AppDelegate+RightSidebarFocusRouting.swift`. Injecting the seam keeps the
/// de-singletonized file explorer testable and lets the composition root decide
/// the routing implementation.
///
/// Every method is main-thread bound (all collaborators are AppKit
/// `NSWindow` / focus-controller state), so the protocol is `@MainActor`.
@MainActor
protocol RightSidebarFocusRouting: AnyObject {
    /// Focuses the right sidebar in the active main window for `mode`, optionally
    /// preferring `preferredWindow`. Returns whether a target window was found and
    /// focused. Mirrors `AppDelegate.focusRightSidebarInActiveMainWindow`.
    @discardableResult
    func focusRightSidebarInActiveMainWindow(
        mode: RightSidebarMode?,
        focusFirstItem: Bool,
        preferredWindow: NSWindow?
    ) -> Bool

    /// Records that the right sidebar received keyboard focus for `mode` in
    /// `window`. Mirrors `AppDelegate.noteRightSidebarKeyboardFocusIntent`.
    func noteRightSidebarKeyboardFocusIntent(mode: RightSidebarMode, in window: NSWindow?)

    /// Registers the file explorer container as the right-sidebar focus host for
    /// `window`'s keyboard-focus coordinator. No-op when the window has no
    /// coordinator. Mirrors
    /// `AppDelegate.keyboardFocusCoordinator(for:)?.registerFileExplorerHost(_:)`.
    func registerFileExplorerHost(_ host: FileExplorerContainerView, in window: NSWindow?)

    /// Moves keyboard focus from the right sidebar back to the terminal for
    /// `window`. Returns whether the terminal accepted focus. Mirrors
    /// `AppDelegate.keyboardFocusCoordinator(for:)?.focusTerminal()`.
    func focusTerminalFromRightSidebar(in window: NSWindow?) -> Bool

    /// Maps `event` to the right-sidebar mode it should activate, honoring the
    /// configured shortcut when-clauses, or `nil` when the event is not a mode
    /// shortcut. Mirrors `AppDelegate.rightSidebarModeShortcut(for:)`.
    func rightSidebarModeShortcut(for event: NSEvent) -> RightSidebarMode?
}
