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
    /// Fails closed: when a non-main window (Settings, a detached panel)
    /// is key, dictation refuses to start rather than typing into a
    /// terminal the user is not looking at. The global fallback applies
    /// only when no window is key at all.
    private func voiceDictationFocusedTerminalPanel() -> TerminalPanel? {
        guard let window = NSApp.keyWindow else {
            return tabManager?.selectedWorkspace?.focusedTerminalPanel
        }
        if let panel = contextForMainTerminalWindow(window)?
            .tabManager.selectedWorkspace?.focusedTerminalPanel {
            return panel
        }
        if let windowId = mainWindowId(from: window),
           let panel = tabManagerFor(windowId: windowId)?
               .selectedWorkspace?.focusedTerminalPanel {
            return panel
        }
        return nil
    }
}
