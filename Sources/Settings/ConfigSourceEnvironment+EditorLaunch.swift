#if os(macOS)
import AppKit
import Foundation

extension ConfigSourceEnvironment {
    /// Opens the materialized Ghostty settings editor files in TextEdit.
    ///
    /// This is the config-domain "open Ghostty Settings" action. It owns its
    /// own behavior end to end: it materializes the editor URL set via
    /// ``materializedGhosttySettingsEditorURLs()`` on `self`, then opens them
    /// with `NSWorkspace`. It carries no terminal-engine state, so it lives on
    /// the config-source value type that produces the URLs rather than on the
    /// `GhosttyApp` libghostty singleton, where it only ever sat by scope.
    ///
    /// Callers (the app `Settings…`/`Ghostty Settings…` menu and the
    /// `palette.openGhosttySettings` command) invoke it directly on
    /// `ConfigSourceEnvironment.live()`, so the action no longer reaches through
    /// `GhosttyApp.shared`.
    func openInTextEditor() {
        let fileURLs: [URL]
        do {
            fileURLs = try materializedGhosttySettingsEditorURLs()
        } catch {
            NSSound.beep()
            return
        }
        guard !fileURLs.isEmpty else {
            NSSound.beep()
            return
        }
        let editorURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(fileURLs, withApplicationAt: editorURL, configuration: configuration)
    }
}
#endif
