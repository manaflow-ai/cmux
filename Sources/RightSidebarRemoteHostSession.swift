import AppKit
import CmuxSidebar
import Foundation

/// App-side adapter conforming the live right-sidebar state to
/// ``RightSidebarRemoteSession``. Captures the resolved window context, its
/// `FileExplorerState`, and the preferred `NSWindow` once, so the package
/// interpreter drives them without naming any app type. Faithfully mirrors the
/// captures the former `AppDelegate.applyRightSidebarRemoteCommand` made at the
/// top of its body before branching on the command.
@MainActor
final class RightSidebarRemoteHostSession: RightSidebarRemoteSession {
    private let context: AppDelegate.RegisteredMainWindow?
    private let state: FileExplorerState
    private let preferredWindow: NSWindow?
    private unowned let host: AppDelegate

    init(
        context: AppDelegate.RegisteredMainWindow?,
        state: FileExplorerState,
        preferredWindow: NSWindow?,
        host: AppDelegate
    ) {
        self.context = context
        self.state = state
        self.preferredWindow = preferredWindow
        self.host = host
    }

    var isVisible: Bool { state.isVisible }

    var mode: RightSidebarMode { state.mode }

    func setVisible(_ visible: Bool) {
        state.setVisible(visible)
    }

    func setMode(_ mode: RightSidebarMode) {
        state.mode = mode
    }

    func toggle() -> Bool {
        host.toggleRightSidebarInActiveMainWindow(preferredWindow: preferredWindow)
    }

    func focus(mode: RightSidebarMode) -> Bool {
        host.focusRightSidebarInActiveMainWindow(
            mode: mode,
            focusFirstItem: true,
            preferredWindow: preferredWindow
        )
    }

    func restoreTerminalFocusIfNeeded() {
        _ = context?.keyboardFocusCoordinator.restoreTerminalFocusAfterRightSidebarHiddenIfNeeded()
    }

    func rememberMode(_ mode: RightSidebarMode) {
        context?.keyboardFocusCoordinator.rememberRightSidebarMode(mode)
    }
}
