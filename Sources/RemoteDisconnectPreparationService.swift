import Foundation

/// Performs disconnected-placeholder filesystem preparation away from the main actor.
actor RemoteDisconnectPreparationService {
    /// Writes the disconnect placeholder and, when scrollback exists, its replay file.
    func prepare(
        target: String,
        reconnectCommand: String?,
        scrollback: String?,
        scrollbackWasTruncated: Bool = false,
        temporaryDirectory: URL
    ) -> (placeholderCommand: String, replayFileURL: URL?)? {
        guard let placeholderCommand = Workspace.remoteDisconnectPlaceholderScript(
            target: target,
            reconnectCommand: reconnectCommand,
            temporaryDirectory: temporaryDirectory
        ) else {
            return nil
        }
        return (
            placeholderCommand: placeholderCommand,
            replayFileURL: SessionScrollbackReplayStore.replayFileURL(
                for: scrollback,
                scrollbackWasTruncated: scrollbackWasTruncated,
                tempDirectory: temporaryDirectory
            )
        )
    }

    func discard(placeholderCommand: String, replayFileURL: URL?) {
        try? FileManager.default.removeItem(atPath: placeholderCommand)
        if let replayFileURL {
            try? FileManager.default.removeItem(at: replayFileURL)
        }
    }
}
