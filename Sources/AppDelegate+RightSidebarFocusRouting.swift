import AppKit
import CmuxSidebar

/// App-side conformance wiring `AppDelegate` as the concrete
/// ``RightSidebarFocusRouting`` seam for the file explorer.
///
/// Three of the seam requirements are already satisfied by `AppDelegate`'s
/// existing methods, whose signatures match the protocol exactly:
/// `focusRightSidebarInActiveMainWindow(mode:focusFirstItem:preferredWindow:)`,
/// `noteRightSidebarKeyboardFocusIntent(mode:in:)`, and
/// `rightSidebarModeShortcut(for:)` (all declared in `AppDelegate.swift`). This
/// extension only adds the two coordinator-backed witnesses, each collapsing the
/// legacy `keyboardFocusCoordinator(for: window)?.X` two-step into a single seam
/// call so the file explorer never touches `MainWindowFocusController` directly.
///
/// This conformance is declared in its own file (not in `AppDelegate.swift`) so
/// the file explorer's de-singletonization adds no new surface to the
/// `AppDelegate` god file; the composition root injects the resulting seam.
extension AppDelegate: RightSidebarFocusRouting {
    func registerFileExplorerHost(_ host: FileExplorerContainerView, in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.registerFileExplorerHost(host)
    }

    func focusTerminalFromRightSidebar(in window: NSWindow?) -> Bool {
        keyboardFocusCoordinator(for: window)?.focusTerminal() == true
    }
}
