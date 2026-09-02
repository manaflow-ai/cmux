import AppKit

// Composition and focus resolution for voice dictation. The runtime is owned
// by the SwiftUI composition root; this extension keeps focus resolution out
// of the AppDelegate god file.
extension AppDelegate {
    /// Resolves the focused terminal panel for the key window, mirroring
    /// the multi-window resolution used by other text-insertion features.
    ///
    /// Fails closed when a non-main window (Settings, a detached panel) is key,
    /// or when no key window exists, rather than typing into a terminal the
    /// user is not looking at.
    func voiceDictationFocusedTerminalPanel() -> TerminalPanel? {
        guard let window = NSApp.keyWindow else { return nil }

        // The focus controller is authoritative even while AppKit's first
        // responder is still a stale main-terminal view (a common transition
        // state when the right sidebar is being mounted). Resolve the Dock's
        // selected terminal when it owns focus and reject every other sidebar
        // mode so text can never land in an invisible main PTY.
        guard let context = contextForMainTerminalWindow(window) else {
            return nil
        }
        switch context.keyboardFocusCoordinator.activeRightSidebarMode {
        case .dock:
            guard let dock = existingWindowDock(forWindowId: context.windowId),
                  let panelId = dock.focusedPanelId,
                  dock.isVisibleInUI,
                  dock.panelIsActiveInVisibleDockPane(panelId),
                  let panel = dock.panels[panelId] as? TerminalPanel else {
                return nil
            }
            return panel
        case .some:
            return nil
        case nil:
            return context.tabManager.selectedWorkspace?.focusedTerminalInputTarget()?.panel
        }
    }
}
