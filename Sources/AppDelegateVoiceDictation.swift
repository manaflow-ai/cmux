import AppKit
import CmuxSettings

// Composition and focus resolution for voice dictation. The stored
// `voiceDictationCoordinator` property lives in AppDelegate.swift; this
// extension keeps everything else out of the god file.
extension AppDelegate {
    func makeVoiceDictationCoordinator() -> VoiceDictationCoordinator {
        VoiceDictationCoordinator(
            catalog: settingsRuntime?.catalog ?? SettingCatalog(),
            focusedTerminalPanel: { [weak self] in
                self?.voiceDictationFocusedTerminalPanel()
            }
        )
    }

    /// Resolves the focused terminal panel for the key window, mirroring
    /// the multi-window resolution used by other text-insertion features.
    ///
    /// Fails closed when a non-main window (Settings, a detached panel) is key,
    /// rather than typing into a terminal the user is not looking at. If no key
    /// window exists during startup, the app-level fallback remains available.
    func voiceDictationFocusedTerminalPanel() -> TerminalPanel? {
        guard let window = NSApp.keyWindow else {
            // There is no window-owned focus state to consult in this narrow
            // startup/test state; preserve the app-level fallback while still
            // projecting a remote-tmux container to its active input pane.
            return tabManager?.selectedWorkspace?.focusedTerminalInputTarget()?.panel
        }

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
