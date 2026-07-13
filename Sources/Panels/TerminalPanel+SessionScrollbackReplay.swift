import Foundation

extension TerminalPanel {
    func adoptOwnedSessionScrollbackReplayArtifact(_ fileURL: URL?) {
        ownedSessionScrollbackReplayFileURL = fileURL
        if fileURL != nil {
            hostedView.beginSessionScrollbackReplay()
        }
    }

    /// Removes only the replay artifact created for this runtime by session restoration.
    func removeOwnedSessionScrollbackReplayArtifact() {
        guard let fileURL = ownedSessionScrollbackReplayFileURL else { return }
        ownedSessionScrollbackReplayFileURL = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}
