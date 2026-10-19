import AppKit
import CmuxTerminal
import Foundation

extension TerminalPanel {
    /// Inserts the path of the newest screenshot into this terminal.
    ///
    /// The command palette action, its shortcut, and the Dock route all end
    /// here. The screenshot folder (the `com.apple.screencapture` `location`
    /// preference, default `~/Desktop`) is read off the main thread without
    /// writing anything. The file then takes the same transfer path as
    /// dropping it on the terminal: a shell-escaped local path, or an upload
    /// plus the remote path for SSH and remote workspaces. A missing
    /// screenshot or a refused transfer beeps.
    func pasteLastScreenshot() {
        Task { @MainActor [weak self] in
            let screenshot = await Task.detached(priority: .userInitiated) {
                ScreenshotLocator(
                    preferences: SystemScreenCapturePreferences(),
                    fileManager: .default,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                ).newestScreenshot()
            }.value
            guard let self else { return }
#if DEBUG
            cmuxDebugLog(
                "terminal.pasteLastScreenshot panel=\(self.id.uuidString.prefix(5)) " +
                "found=\(screenshot == nil ? 0 : 1)"
            )
#endif
            guard let screenshot,
                  self.hostedView.surfaceView.executePreparedImageTransfer(
                      .fileURLs([screenshot]),
                      mode: .drop,
                      onCancel: {}
                  ) else {
                NSSound.beep()
                return
            }
        }
    }
}
