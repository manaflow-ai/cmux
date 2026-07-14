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
    private func voiceDictationFocusedTerminalPanel() -> TerminalPanel? {
        if let window = NSApp.keyWindow {
            if let panel = contextForMainTerminalWindow(window)?
                .tabManager.selectedWorkspace?.focusedTerminalPanel {
                return panel
            }
            if let windowId = mainWindowId(from: window),
               let panel = tabManagerFor(windowId: windowId)?
                   .selectedWorkspace?.focusedTerminalPanel {
                return panel
            }
        }
        return tabManager?.selectedWorkspace?.focusedTerminalPanel
    }
}
