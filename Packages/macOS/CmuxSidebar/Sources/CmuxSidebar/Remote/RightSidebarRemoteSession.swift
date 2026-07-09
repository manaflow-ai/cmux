import Foundation

/// The live, app-side right sidebar a remote command operates on, resolved once
/// per command. It wraps the addressed window's `FileExplorerState` plus the
/// window/focus collaborators the interpreter drives, so the package never names
/// those app types. The app provides the conforming adapter.
@MainActor
public protocol RightSidebarRemoteSession: AnyObject {
    /// Whether the sidebar is currently visible.
    var isVisible: Bool { get }
    /// The currently selected mode.
    var mode: RightSidebarMode { get }
    /// Sets visibility without changing the mode.
    func setVisible(_ visible: Bool)
    /// Selects a mode without changing visibility or focus.
    func setMode(_ mode: RightSidebarMode)
    /// Toggles the right sidebar in the resolved window; `false` if unavailable.
    func toggle() -> Bool
    /// Focuses the sidebar in the given mode (first item); `false` on failure.
    func focus(mode: RightSidebarMode) -> Bool
    /// Restores terminal focus after the sidebar was hidden, if needed.
    func restoreTerminalFocusIfNeeded()
    /// Records the mode as the remembered keyboard-focus mode.
    func rememberMode(_ mode: RightSidebarMode)
}
