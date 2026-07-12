import Foundation

extension TerminalPanel {
    /// Removes only the replay artifact created for this runtime by session restoration.
    func removeOwnedSessionScrollbackReplayArtifact(
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        guard let path = surface.startupEnvironmentValue(SessionScrollbackReplayStore.environmentKey),
              !path.isEmpty else { return }
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        let replayDirectory = tempDirectory
            .appendingPathComponent("cmux-session-scrollback", isDirectory: true)
            .standardizedFileURL
        guard fileURL.deletingLastPathComponent() == replayDirectory else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
