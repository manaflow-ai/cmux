import Foundation

extension TerminalPanel {
    func adoptOwnedSessionScrollbackReplayArtifact(_ fileURL: URL?) {
        ownedSessionScrollbackReplayFileURL = fileURL
    }

    /// Removes only the replay artifact created for this runtime by session restoration.
    func removeOwnedSessionScrollbackReplayArtifact() {
        guard let fileURL = ownedSessionScrollbackReplayFileURL else { return }
        ownedSessionScrollbackReplayFileURL = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}
