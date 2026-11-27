import Foundation

/// Performs disconnected-placeholder filesystem preparation away from the main actor.
actor RemoteDisconnectPreparationService {
    func prepare(
        target: String,
        reconnectCommand: String?,
        scrollback: String?,
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
